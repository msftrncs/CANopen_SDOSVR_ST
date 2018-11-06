

(* @NESTEDCOMMENTS := 'Yes' *)
(* @PATH := '\/SDO Server' *)
(* @OBJECTFLAGS := '0, 8' *)
(* @SYMFILEFLAGS := '2048' *)
FUNCTION_BLOCK FB_SDOSVR_PROC (* hardware independent SDO Server processor instance *)
VAR_INPUT
	CANSDO_DATA : ARRAY [0..7] OF BYTE; (* Data from / to CAN preprocessor *)
	CANSDO_DLC : BYTE; (* data bytes used in CANSDO_DATA buffer *)
	CANSDO_IsEnum : BOOL; (* processing an enumeration request? (silences errors) *)

	Std_XfrUp_TO_TIME : TIME := t#0s; (* standard time-out time for uploads, t#0s disables *)
	Std_XfrDn_TO_TIME : TIME := t#2s; (* standard time-out time for downloads, t#0s disables *)

	(* for Object Handler Responses *)
	Response_BUFFER_PTR : POINTER TO ARRAY[0..6] OF BYTE; (* pointer to a bytewise buffer for the response *)
	Response_BUFFER_LEN : DWORD; (* length of data at BUFFER_PTR for upload or space available at BUFFER_PTR to download data (bytes) *)
	Response_TO_TIME : TIME; (* optionally specified time-out time for this transfer, t#0s should have no time-out, defaults to standard TO time specified for appropriate direction *)
END_VAR
VAR_OUTPUT
	CANSDO_TX : BOOL := FALSE; (* preprocessor should transmit data buffer as response *)

	Request_RESULT : BYTE := 0; (* result of any pending request processing, 0=nothing to process, 1=more to process, 2=dispatching upload request, 3=dispatching download request, 4=terminating download normal, 5=aborting download, 6=pending aborted download, 7=pending expedited download acknowledgement *)
		(* Understanding Requst_RESULT:
			0 = There is no active transfer occuring, however, CANSDO_TX could be pending a transmission to complete the last transfer.
			1 = A transfer is ongoing, CANSDO_TX could be pending a transmission as part of the transfer.
			2 = Application needs to respond to an upload request, either supplying the requested object, or requesting an INV_SIDX or W_ONLY error, else an automatic INV_OBJ error will be sent.
			3 = Application needs to respond to a download request, either supplying a destination for the requested object, requesting an INV_SIDX or other suitable error, else an automatic INV_OBJ error will be sent.
			4 = Application needs to respond to a download completion, optionally requesting an error be sent if neccessary, else an aknowledgement will be sent. (BufferOverrun is considered normal completion, app is to check Response_BUFFEROVERRUN)
			5 = Application is being notified of an aborted download, CANSDO_TX could be pending a transmission to signal an internal error, application not permitted to request an error indication.
			6 = An abortion of a download is pending from an application action, will be applied at next cleanup, this is a private RESULT and application shall not react to it.
			7 = Acknowledgment of an expedited download is pending from an application action, will be applied at next cleanup.  *)
	Request_OBJ : WORD; (* Object ID of the SDO request *)
	Request_SIDX : BYTE; (* object sub-index of the SDO request *)
	Request_EXP : BOOL; (* Request is expedited (result = download request only, invalid all other times) *)
	Request_LEN : DWORD; (* length of data requested to be downloaded if known, or total downloaded at termination *)
	Request_LEN_KNOWN : BOOL; (* length of request is known, LEN is valid *)
	Request_BUFFEROVERRUN : BOOL; (* even though normal termination of download, download buffer was overrun, will result in OUT_OF_MEM error if a different error is not specified *)
END_VAR
VAR
	ActXfr_Up : BOOL := FALSE; (* is an active upload in progress (request has been handled and segments are waiting to be sent *)
	ActXfr_Up_OBJ : WORD; (* Object ID of the active upload *)
	ActXfr_Up_SIDX : BYTE; (* object sub-index of the active upload *)
	ActXfr_Up_BufPtr : POINTER TO ARRAY[0..6] OF BYTE; (* current location in buffer from which we are sending data *)
	ActXfr_Up_BufRem : DWORD; (* length of buffer remaining to be transfered *)
	ActXfr_Up_SeqTog : BOOL; (* toggle status of 't' sequence last sent *)
	ActXfr_Up_LTMR : TOS; (* timer to track silence of the upload acknowledgements *)

	ActXfr_Dn : BOOL := FALSE; (* is an active download in progress (request has been handled and waiting for segments to be received *)
	ActXfr_Dn_OBJ : WORD; (* Object ID of the active download *)
	ActXfr_Dn_SIDX : BYTE; (* object sub-index of the active download *)
	ActXfr_Dn_BufPtr : POINTER TO ARRAY[0..6] OF BYTE; (* current location in buffer in which to place receive data *)
	ActXfr_Dn_BufLen : DWORD; (* total length of buffer *)
	ActXfr_Dn_DLC : DWORD; (* length of data transfered so far *)
	ActXfr_Dn_SeqTog : BOOL; (* toggle status of 't' sequence of next expected packet *)
	ActXfr_Dn_LTMR : TOS; (* timer to track silence of the download data segments *)

	CMD_N : BYTE; (* number of data bytes used in the payload (this packet), this can be influenced by packet DLC if S bit not set when E bit is set *)

	i : USINT; (* character counter *)
END_VAR
VAR CONSTANT
(*
	2017-01-30 CMM V1.0001, added ENUM flag which prevents error responses, INV_OBJ, INV_SIDX and BAD_CMD's to initiate requests, fixed
	BAD_CMD response to prevent aborting an already active session for the same object.  Added TX ACK_EXP_DN and TX_EXP_UP_RESP to allow
	object handlers to expedite handling of expedite results, which should reduce redundant buffer copies.

	2018-11-01 CMM V1.0002, removed CMD_CCS (BYTE) from VAR, implemented directly in CASE statement.  Segment Upload (CCS=3) didn't clear TO timer
	upon normal completion.  Optimization in Segment Download (CCS=0) not update buffer pointer upon termination.  Request_LEN was filled
	even when NOT Request_LEN_KNOWN for non-expedited downloads, is now set = 0.  TX_ACK_EXP_DN action clears CANSDO_IsEnum, DispatchResponse altered
	to not duplicate this action.  Action TX_ERR_NO_DATA was marked private.  Actions TX_ERR_BAD_SIZE, TX_ERR_INV_VAL, TX_ERR_NO_DATA, TX_ERR_R_ONLY, 
	TX_ERR_W_ONLY now clear CANSDO_IsEnum.  Clarified some comments, added comments to clarify some code.  TX_EXP_UP_RESP now limits Request_LEN to
	maximum of 4 incase of bad input.  Added CleanUp to CLEAR_TX_REQ.
*)
	SDOSVR_Version : DWORD := 10002; (* version of SDO Server Processor, Vx.yzzz *)
END_VAR

(* @END_DECLARATION := '0' *)
(* when called, there is data to process in RX buffers *)
IF CANSDO_DLC >= 1 THEN
	(* there must be at least 1 byte in order to be a valid command, which could be for a segmented or block transfer *)
	(* SDO command value; 0 segment download, 1 initiate download, 2 initiate upload, 3 segment upload, 4 abort, 5 block transfer upload, 6 block transfer download, 7 reserved *)
	CASE SHR( CANSDO_DATA[0], 5 ) OF
	0:	(* segmented download data packet *)
		IF ActXfr_Dn THEN
			CMD_N := 7 - (SHR( CANSDO_DATA[0], 1 ) AND 7); (* number of data bytes in payload *)
			IF ((CANSDO_DLC - 1) < CMD_N) OR (CANSDO_DATA[0].4 <> ActXfr_Dn_SeqTog) THEN
				(* datagram inconsistency, abort transfer *)
				ActXfr_Dn := FALSE;
				Request_BUFFEROVERRUN := FALSE; (* not aborting because of a buffer overrun *)
				Request_LEN := ActXfr_Dn_DLC;
				Request_OBJ := ActXfr_Dn_OBJ;
				Request_SIDX := ActXfr_Dn_SIDX;
				Request_RESULT := 5; (* aborting the download *)
				IF (CANSDO_DLC - 1) < CMD_N THEN
					(* there is no valid error code for bad formatted request, but TX_ERR_BAD_CMD requires the OBJ/SIDX to already be in the CAN buffer. *)
					CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
					CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
					CANSDO_DATA[3] := Request_SIDX; (* sub index *)
					TX_ERR_BAD_CMD; (* signal bad command error *)
				ELSE
					TX_ERR_SEG_TOG; (* signal segment sequence error *)
				END_IF
				ActXfr_Dn_LTMR.C; (* clearing inactivity timer *)
			ELSE
				(* transfer these bytes to the buffer, checking for overflow *)
				i := 0;
				WHILE i < CMD_N DO
					IF ActXfr_Dn_DLC + i >= ActXfr_Dn_BufLen THEN
						EXIT; (* cannot process any more data *)
					END_IF
					ActXfr_Dn_BufPtr^[i] := CANSDO_DATA[i + 1];
					i := i + 1; (* next byte *)
				END_WHILE
				ActXfr_Dn_DLC := ActXfr_Dn_DLC + i; (* add bytes processed *)
				IF i <> CMD_N OR CANSDO_DATA[0].0 THEN
					(* either ran out of buffer or segmented transfer is complete *)
					ActXfr_Dn := FALSE;
					Request_BUFFEROVERRUN := i <> CMD_N;
					Request_LEN := ActXfr_Dn_DLC;
					Request_OBJ := ActXfr_Dn_OBJ;
					Request_SIDX := ActXfr_Dn_SIDX;
					Request_RESULT := 4; (* finishing the download normal, even if buffer overrun *)
					IF Request_BUFFEROVERRUN THEN
						(* need to report 'out of memory' error to client, but could be overwritten by app using another error *)
						TX_ERR_OUT_OF_MEM;
					ELSE
						TX_CNFM_SEG_DN; (* note this final confirmation may be overwritten by an error message *)
					END_IF
					ActXfr_Dn_LTMR.C; (* clearing inactivity timer *)
				ELSE
					ActXfr_Dn_BufPtr := ActXfr_Dn_BufPtr + USINT_TO_DWORD( i ); (* advance buffer pointer *)
					ActXfr_Dn_SeqTog := NOT ActXfr_Dn_SeqTog; (* toggle T expected next *)
					IF ActXfr_Dn_LTMR.IN THEN
						ActXfr_Dn_LTMR.SR; (* reset timer, if already active *)
					END_IF
					TX_CNFM_SEG_DN; (* prepare confirmation of segment *)
				END_IF
			END_IF
		END_IF
	1:	(* initiate download request/data packet, ignore if not at least 4 bytes of data *)
		IF CANSDO_DLC >= 4 THEN
			(* we need at least 4 bytes to attempt processing an initiate download request/data packet *)
			Request_OBJ := SHL( BYTE_TO_WORD( CANSDO_DATA[2] ), 8 ) + BYTE_TO_WORD( CANSDO_DATA[1] );
			Request_SIDX := CANSDO_DATA[3];
			Request_LEN_KNOWN := CANSDO_DATA[0].0; (* length known if was present in command *)
			Request_EXP := CANSDO_DATA[0].1; (* download expedited? *)
			IF Request_EXP THEN
				(* expedited, packet includes data, determine how many bytes and check if valid *)
				Request_EXP := TRUE;
				CMD_N := SEL( Request_LEN_KNOWN, CANSDO_DLC - 4, 4 - (SHR( CANSDO_DATA[0], 2 ) AND 3) );
				IF (CMD_N = 0) OR ((CANSDO_DLC - 4) < CMD_N) THEN
					TX_ERR_BAD_CMD; (* command doesn't make sense, not enough data was supplied *)
				ELSE
					Request_LEN := CMD_N; (* databytes either specified or that were present when unspecified *)
					Request_RESULT := 3; (* dispatch a download *)
				END_IF
			ELSE
				(* download request, data to follow, is data length specified? *)
				IF SEL( Request_LEN_KNOWN, FALSE, CANSDO_DLC < 8 ) THEN
					TX_ERR_BAD_CMD; (* command doesn't make sense, not enough data was supplied *)
				ELSE
					Request_LEN := SEL( Request_LEN_KNOWN, 0, SHL( BYTE_TO_DWORD( CANSDO_DATA[7] ), 24 ) +
					  SHL( BYTE_TO_DWORD( CANSDO_DATA[6] ), 16 ) + SHL( BYTE_TO_DWORD( CANSDO_DATA[5] ), 8 ) + CANSDO_DATA[4] );
					Request_RESULT := 3; (* dispatch a download *)
					Response_TO_TIME := Std_XfrDn_TO_TIME; (* set response default TO time to standard *)
				END_IF
			END_IF
		END_IF
	2:	(* initiate upload request packet *)
		IF CANSDO_DLC >= 4 THEN
			(* we need at least 4 bytes to attempt processing an initiate upload request packet *)
			Request_OBJ := SHL( BYTE_TO_WORD( CANSDO_DATA[2] ), 8 ) + BYTE_TO_WORD( CANSDO_DATA[1] );
			Request_SIDX := CANSDO_DATA[3];
			Request_RESULT := 2; (* dispatch an upload *)
			Response_TO_TIME := Std_XfrUp_TO_TIME; (* set response default TO time to standard *)
		END_IF
	3:	(* segmented upload confirmation packet *)
		IF ActXfr_Up THEN
			IF CANSDO_DATA[0].4 <> ActXfr_Up_SeqTog THEN
				(* datagram inconsistency, abort transfer *)
				ActXfr_Up := FALSE;
				Request_RESULT := SEL( ActXfr_Dn, 0, 1 ); (* reflect if another transfer in progress *)
				Request_OBJ := ActXfr_Up_OBJ;
				Request_SIDX := ActXfr_Up_SIDX;
				TX_ERR_SEG_TOG; (* signal segment sequence error *)
				ActXfr_Up_LTMR.C; (* clearing inactivity timer *)
			ELSE
				(* request for the next segment, prepare it *)
				i := 0;
				WHILE i < ActXfr_Up_BufRem DO
					CANSDO_DATA[i + 1] := ActXfr_Up_BufPtr^[i];
					i := i + 1;
					IF i = 7 THEN
						EXIT; (* cannot process any more data *)
					END_IF
				END_WHILE
				ActXfr_Up_BufRem := ActXfr_Up_BufRem - i;
				IF ActXfr_Up_BufRem = 0 THEN
					ActXfr_Up := FALSE; (* transfer is complete *)
					Request_RESULT := SEL( ActXfr_Dn, 0, 1 ); (* reflect if another transfer in progress *)
					ActXfr_Up_LTMR.C; (* clearing inactivity timer *)
				ELSE
					ActXfr_Up_BufPtr := ActXfr_Up_BufPtr + USINT_TO_DWORD( i ); (* update buffer for next segment *)
				END_IF
				CANSDO_DATA[0] := SEL( ActXfr_up_SeqTog, 0, 16 ) + SHL( 7 - i, 1 ) + SEL( ActXfr_Up, 1 , 0 ); (* response with number of bytes we didn't use, and if this response completes the transfer *)
				WHILE i < 7 DO
					CANSDO_DATA[i + 1] := 0; (* clearing unused portion per specification *)
					i := i + 1;
				END_WHILE
				CANSDO_DLC := 8;
				CANSDO_TX := TRUE;
				ActXfr_Up_SeqTog := NOT ActXfr_Up_SeqTog; (* waiting for next toggle *)
				IF ActXfr_Up_LTMR.IN THEN
					ActXfr_Up_LTMR.SR; (* reset inactivity timer, only if already active *)
				END_IF
			END_IF
		END_IF
	4:	(* abort notice packet *)
		IF CANSDO_DLC >= 4 THEN
			(* datagram has enough bytes *)
			Request_OBJ := SHL( BYTE_TO_WORD( CANSDO_DATA[2] ), 8 ) + BYTE_TO_WORD( CANSDO_DATA[1] );
			Request_SIDX := CANSDO_DATA[3];
			IF SEL( ActXfr_Dn, FALSE, ActXfr_Dn_OBJ = Request_OBJ AND ActXfr_Dn_SIDX = Request_SIDX ) THEN
				(* abort was for current download, let application know download aborted *)
				ActXfr_Dn := FALSE;
				Request_BUFFEROVERRUN := FALSE;
				Request_LEN := ActXfr_Dn_DLC;
				Request_RESULT := 5; (* aborting the download *)
				ActXfr_Dn_LTMR.C; (* clearing inactivity timer *)
			ELSIF SEL( ActXfr_Up, FALSE, ActXfr_Up_OBJ = Request_OBJ AND ActXfr_Up_SIDX = Request_SIDX ) THEN
				(* abort was for current upload, thats good *)
				ActXfr_Up := FALSE;
				Request_RESULT := SEL( ActXfr_Dn, 0, 1 ); (* reflect if another transfer in progress *)
				ActXfr_Up_LTMR.C; (* clearing inactivity timer *)
			END_IF
		END_IF
	ELSE
		(* note 5, 6 (block transfers) and 7 (reserved) are not currently handled, will result in an error of BAD_CMD *)
		(* regarding block transfers, block transfers have additional restrictions:
			  Only one block transfer can be active at a time, regardless of direction.
			  Standard transfers (expedited or segmented) cannot be used while a block transfer is active.  They cannot be differentiated from the block segments.
			  An abort must have byte 0 as exactly 0x80, because block segment sequence numbers can range from 1-0x7F and 0x81-0xFF (when marked last block).
		   So that said, block transfers really only suit applications with very limited 1:1 access, such as bulk downloads on dedicated ID's, and with secured processes.
		   And with that, there will likely never be any need for block transfers with this code.
		*)
		IF CANSDO_DLC >= 4 THEN
			(* must have at least 4 data bytes to respond with a BAD_CMD error, anything else we just ignore *)
			TX_ERR_BAD_CMD;
		END_IF
	END_CASE
END_IF

END_FUNCTION_BLOCK
ACTION	ChkTimers:
IF ActXfr_Up THEN
	IF ActXfr_Up_LTMR.IN THEN
		ActXfr_Up_LTMR; (* update upload inactivity timer *)
		IF NOT ActXfr_Up_LTMR.Q THEN
			(* inactivity timer has expired *)
			ActXfr_Up := FALSE;
			Request_RESULT := SEL( ActXfr_Dn, 0, 1 ); (* reflect if another transfer in progress *)
			Request_OBJ := ActXfr_Dn_OBJ;
			Request_SIDX := ActXfr_Dn_SIDX;
			TX_ERR_TIME_OUT;
		END_IF
	END_IF
END_IF

(* we can only check the download timer if the upload timer didn't generate an error transmission *)
IF ActXfr_Dn AND NOT CANSDO_TX THEN
	IF ActXfr_Dn_LTMR.IN THEN
		ActXfr_Dn_LTMR; (* update download inactivity timer *)
		IF NOT ActXfr_Dn_LTMR.Q THEN
			(* inactivity timer has expired *)
			ActXfr_Dn := FALSE;
			Request_BUFFEROVERRUN := FALSE; (* not aborting because of a buffer overrun *)
			Request_LEN := ActXfr_Dn_DLC;
			Request_OBJ := ActXfr_Dn_OBJ;
			Request_SIDX := ActXfr_Dn_SIDX;
			Request_RESULT := 5; (* aborting the download *)
			TX_ERR_TIME_OUT;
		END_IF
	END_IF
END_IF

END_ACTION

ACTION	CleanUp:
(* Processing CleanUp, intended for the CAN implementation to utilize if Request_RESULT is > 1 prior
   to processing of the next received request. *)
(* handle cleanup if application doesn't react to Request_RESULT, as its not really required to *)
CASE Request_RESULT OF
2,3:
	(* download or upload request was not acted upon, must be an invalid object *)
	TX_ERR_INV_OBJ; (* object of request must have been invalid and could not be found *)
4,5:
	(* when = 4, applicatiom must have accepted the download completion without error *)
	Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );
6:
	(* application accepted an upload request which coincides with an active download,
	   the download is being aborted, so notify the application.  *)
	Request_RESULT := 5;
7:
	(* application must have accepted the expedited download without error *)
	TX_ACK_EXP_DN;
END_CASE

END_ACTION

ACTION	CLEAR_TX_REQ:
(* CAN interface has transmitted our buffer, intended for use by the CAN preprocessor *)
CANSDO_TX := FALSE;
CleanUp; (* clear TX flag and clean up previous request results or pending actions *)
END_ACTION

ACTION	DispatchResponse:
(* respond with a normal dispatch response *)
IF Request_RESULT = 2 THEN
	(* response is from an upload request, responder indicated size, prepare a response packet *)
	IF (Response_BUFFER_LEN <= 4) AND (Response_BUFFER_LEN > 0) THEN
		(* expedited response (responses with 1 to 4 bytes) *)
		i := 0;
		WHILE i < Response_BUFFER_LEN DO
			CANSDO_DATA[i + 4] := Response_BUFFER_PTR^[i]; (* copy data *)
			i := i + 1;
		END_WHILE
		WHILE i < 4 DO
			CANSDO_DATA[i + 4] := 0; (* blank unused bytes per specification *)
			i := i + 1;
		END_WHILE
		TX_EXP_UP_RESP; (* let action complete this transaction *)
	ELSE
		(* standard response with segmented transfer to CONTINUE *)
		ActXfr_Up_BufPtr := Response_BUFFER_PTR;
		ActXfr_Up_BufRem := Response_BUFFER_LEN;
		ActXfr_Up_OBJ := Request_OBJ;
		ActXfr_Up_SIDX := Request_SIDX;
		CANSDO_DATA[0] := 16#41; (* segmented upload response *)
		(* OBJ and SIDX are still loaded in buffer *)
		CANSDO_DATA[4] := DWORD_TO_BYTE( ActXfr_Up_BUFREM );
		CANSDO_DATA[5] := DWORD_TO_BYTE( SHR( ActXfr_Up_BUFREM, 8 ) );
		CANSDO_DATA[6] := DWORD_TO_BYTE( SHR( ActXfr_Up_BUFREM, 16 ) );
		CANSDO_DATA[7] := DWORD_TO_BYTE( SHR( ActXfr_Up_BUFREM, 24 ) );
		ActXfr_Up_SeqTog := FALSE; (* starting on first segment sequence *)
		ActXfr_Up := TRUE;
		IF SEL( ActXfr_Dn, FALSE, ActXfr_Dn_OBJ = Request_OBJ AND ActXfr_Dn_SIDX = Request_SIDX ) THEN
			(* active download is for same object, must silently abort it and let application know it was aborted. *)
			ActXfr_Dn := FALSE;
			Request_BUFFEROVERRUN := FALSE;
			Request_LEN := ActXfr_Dn_DLC;
			Request_OBJ := ActXfr_Dn_OBJ;
			Request_SIDX := ActXfr_Dn_SIDX;
			Request_RESULT := 6; (* aborting the download on next cycle *)
			ActXfr_Dn_LTMR.C; (* clearing inactivity timer *)
		ELSE
			Request_RESULT := 1; (* we're active *)
		END_IF
		IF Response_TO_TIME <> t#0s THEN
			ActXfr_Up_LTMR.SR( PT:=Response_TO_TIME ); (* reset inactivity timer *)
		ELSE
			ActXfr_Up_LTMR.C; (* clear timer, not requested for this response *)
		END_IF
		CANSDO_DLC := 8;
		CANSDO_TX := TRUE;
		CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)
	END_IF
ELSIF Request_RESULT = 3 THEN
	(* response is from a download request *)
	IF Request_EXP THEN
		(* download was expedited, data already supplied, transfer to app, tell how many bytes we got and if we overrun the buffer *)
		i := 0;
		WHILE i < Request_LEN DO
			IF i >= Response_BUFFER_LEN THEN
				EXIT;
			END_IF
			Response_BUFFER_PTR^[i] := CANSDO_DATA[i + 4]; (* copy data *)
			i := i + 1;
		END_WHILE
		Request_LEN := i; (* length of data downloaded *)
		(* if request length was known, then its a problem if there was more data than buffer, but not if length was not known *)
		Request_BUFFEROVERRUN := SEL( Request_LEN_KNOWN, FALSE, i > Response_BUFFER_LEN );
		Request_RESULT := 7; (* pending an aknowledgement of expedited download *)
	ELSE
		(* download is segmented, RETURN a confirmation message to start segments flowing *)
		ActXfr_Dn_BufPtr := Response_BUFFER_PTR;
		ActXfr_Dn_BufLen := Response_BUFFER_LEN;
		ActXfr_Dn_DLC := 0;
		ActXfr_Dn_OBJ := Request_OBJ;
		ActXfr_Dn_SIDX := Request_SIDX;
		CANSDO_DATA[0] := 16#60; (* dwonload acknowledge *)
		CANSDO_DATA[4] := CANSDO_DATA[5] := CANSDO_DATA[6] := CANSDO_DATA[7] := 0;
		CANSDO_DLC := 8;
		CANSDO_TX := TRUE;
		ActXfr_Dn := TRUE;
		ActXfr_Dn_SeqTog := FALSE; (* starting on first segment sequence *)
		Request_RESULT := 1; (* we're active *)
		IF Response_TO_TIME <> t#0s THEN
			ActXfr_Dn_LTMR.SR( PT:=Response_TO_TIME ); (* reset inactivity timer *)
		ELSE
			ActXfr_Dn_LTMR.C; (* clear timer, not requested for this response *)
		END_IF
		CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)
	END_IF
END_IF

END_ACTION

ACTION	TX_ACK_EXP_DN:
(* acknowledge an expedited download, may be submitted by application object handler *)

CANSDO_DATA[0] := 16#60; (* dwonload acknowledge *)
CANSDO_DATA[4] := CANSDO_DATA[5] := CANSDO_DATA[6] := CANSDO_DATA[7] := 0;
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := 4;

END_ACTION

ACTION	TX_CNFM_SEG_DN:
(* Confirm segment download {Private} *)

CANSDO_DATA[0] := SEL( ActXfr_Dn_SeqTog, 32, 48 ); (* prepare confirmation *)
CANSDO_DATA[1] := CANSDO_DATA[2] := CANSDO_DATA[3] := CANSDO_DATA[4] := CANSDO_DATA[5] := CANSDO_DATA[6] := CANSDO_DATA[7] := 0; (* per specification *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;

END_ACTION

ACTION	TX_ERR_BAD_CMD:
(* TX a ERROR message BAD COMMAND {Private!} *)

(* NOTE: we should not TX a BAD_CMD error if we have an active session with the specified OBJ and SIDX !!!! *)

IF NOT CANSDO_IsEnum THEN
	IF SEL( ActXfr_Dn, TRUE, (ActXfr_Dn_OBJ <> Request_OBJ) OR (ActXfr_Dn_SIDX <> Request_SIDX) ) AND SEL( ActXfr_Up, TRUE, (ActXfr_Up_OBJ <> Request_OBJ) OR (ActXfr_Up_SIDX <> Request_SIDX) ) THEN
		(* command was not recognized *)
		CANSDO_DATA[0] := 16#80; (* Abort command *)
		(* OBJ and SIDX is still in DATA buffer *)
		CANSDO_DATA[4] := 1;
		CANSDO_DATA[5] := 0;
		CANSDO_DATA[6] := 4;
		CANSDO_DATA[7] := 5; (* 0x05040001 *)
		CANSDO_DLC := 8;
		CANSDO_TX := TRUE;
	END_IF
ELSE
	CANSDO_IsEnum := FALSE; (* no longer processing enumeration request *)
END_IF

END_ACTION

ACTION	TX_ERR_BAD_SIZE:
(* TX a ERROR message DATA TYPE DOESN'T MATCH {For Object Handler responses} (for downloads only) *)

(* object data type is wrong size *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
CANSDO_DATA[3] := Request_SIDX; (* sub index *)
CANSDO_DATA[4] := 16#10;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 7;
CANSDO_DATA[7] := 6; (* 0x06070010 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_INV_OBJ:
(* TX a ERROR message INVALID OBJECT {Private!} *)

IF NOT CANSDO_IsEnum THEN
	(* Object does not exist *)
	CANSDO_DATA[0] := 16#80; (* Abort command *)
	(* OBJ and SIDX should still be in CAN DATA buffer *)
	CANSDO_DATA[4] := 0;
	CANSDO_DATA[5] := 0;
	CANSDO_DATA[6] := 2;
	CANSDO_DATA[7] := 6; (* 0x06020000 *)
	CANSDO_DLC := 8;
	CANSDO_TX := TRUE;
ELSE
	CANSDO_IsEnum := FALSE; (* no longer processing enumeration request *)
END_IF

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_INV_SIDX:
(* TX a ERROR message INVALID SUBINDEX {For Object Handler response} *)

IF NOT CANSDO_IsEnum THEN
	(* Object sub-index does not exist *)
	CANSDO_DATA[0] := 16#80; (* Abort command *)
	(* OBJ and SIDX should still be in CAN DATA buffer *)
	CANSDO_DATA[4] := 16#11;
	CANSDO_DATA[5] := 0;
	CANSDO_DATA[6] := 9;
	CANSDO_DATA[7] := 6; (* 0x06090011 *)
	CANSDO_DLC := 8;
	CANSDO_TX := TRUE;
ELSE
	CANSDO_IsEnum := FALSE; (* no longer processing enumeration request *)
END_IF

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_INV_VAL:
(* TX a ERROR message INVALID VALUE {For Object Handler responses} (for downloads only) *)

(* Bad Value for Object *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
CANSDO_DATA[3] := Request_SIDX; (* sub index *)
CANSDO_DATA[4] := 16#30;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 9;
CANSDO_DATA[7] := 6; (* 0x06090030 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_NO_DATA:
(* TX a ERROR message NO DATA {For Object Handler responses} (usually for upload requests that cannot respond due to other criteria) *)

(* Data cannot be accepted or sent at this time *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
(* OBJ and SIDX should still be in CAN DATA buffer *)
CANSDO_DATA[4] := 16#20;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 0;
CANSDO_DATA[7] := 8; (* 0x08000020 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_OUT_OF_MEM:
(* TX a ERROR message to ABORT transfer OUT OF MEMORY {Private!} *)

(* transfer needs to be aborted, use error code 0x05040005, out of memory *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
CANSDO_DATA[3] := Request_SIDX; (* sub index *)
CANSDO_DATA[4] := 5;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 4;
CANSDO_DATA[7] := 5; (* 0x05040005 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;

END_ACTION

ACTION	TX_ERR_R_ONLY:
(* TX a ERROR message VALUE READ ONLY {For Object Handler response} *)

(* Object is READ only *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
(* OBJ and SIDX should still be in CAN DATA buffer *)
CANSDO_DATA[4] := 2;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 1;
CANSDO_DATA[7] := 6; (* 0x06010002 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_ERR_SEG_TOG:
(* TX a ERROR message WRONG SEGMENT TOGGLE {Private!} *)

(* segmented transfer needs to be aborted, request is not for next segment, use error code 0x05040002, expecting next segment transfer *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
CANSDO_DATA[3] := Request_SIDX; (* sub index *)
CANSDO_DATA[4] := 2;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 4;
CANSDO_DATA[7] := 5; (* 0x05040002 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;

END_ACTION

ACTION	TX_ERR_TIME_OUT:
(* TX an ERROR message to ABORT transfer TIME OUT {Private!} *)

(* transfer needs to be aborted, use error code 0x05040000, time-out *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
CANSDO_DATA[1] := WORD_TO_BYTE( Request_OBJ AND 16#FF ); (* low order of index *)
CANSDO_DATA[2] := WORD_TO_BYTE( SHR( Request_OBJ, 8 ) ); (* high order of index *)
CANSDO_DATA[3] := Request_SIDX; (* sub index *)
CANSDO_DATA[4] := 0;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 4;
CANSDO_DATA[7] := 5; (* 0x05040000 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;

END_ACTION

ACTION	TX_ERR_W_ONLY:
(* TX a ERROR message VALUE WRITE ONLY {For Object Handler response} *)

(* Object is WRITE only! *)
CANSDO_DATA[0] := 16#80; (* Abort command *)
(* OBJ and SIDX should still be in CAN DATA buffer *)
CANSDO_DATA[4] := 1;
CANSDO_DATA[5] := 0;
CANSDO_DATA[6] := 1;
CANSDO_DATA[7] := 6; (* 0x06010002 *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 );

END_ACTION

ACTION	TX_EXP_UP_RESP:
(* TX an expedited upload response, OBJ, SIDX and DATA are loaded in CAN message, Response_BUFFER_LEN is length specified, 0 = unspecified *)
(* application object dispatch may directly expedite data to CANSDO_DATA[4..7] and submit here to complete transaction (only way to submit an unspecified length) *)

CANSDO_DATA[0] := 16#43 + SEL( Response_BUFFER_LEN = 0, SHL( 4 - DWORD_TO_BYTE( MIN( Response_BUFFER_LEN, DWORD#4 ) ), 2 ), -1 ); (* encode response length, note -1 when no length specified *)
CANSDO_DLC := 8;
CANSDO_TX := TRUE;
CANSDO_IsEnum := FALSE; (* if this was an enumeration request, we've completed it *)

Request_RESULT := SEL( ActXfr_Dn OR ActXfr_Up, 0, 1 ); (* any other transfers pending? *)

END_ACTION
