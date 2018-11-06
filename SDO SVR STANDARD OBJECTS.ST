

(* @NESTEDCOMMENTS := 'Yes' *)
(* @PATH := '\/SDO Server' *)
(* @OBJECTFLAGS := '0, 8' *)
(* @SYMFILEFLAGS := '2048' *)
FUNCTION_BLOCK FB_SDOSVR_STDOBJS
VAR_INPUT
	SDOSVR_PROC : POINTER TO FB_SDOSVR_PROC;

	DeviceType_Profile : WORD := 0; (* device profile this device supports, 0 indicates no predefined device (ex: 401 indicates input/output device profile DS401) *)
	DeviceType_Features : WORD := 0; (* device profile features this device supports, or 16#FFFF to indicate a multi-profile device ???  *)

	OBJ_DevName_String : POINTER TO STRING; (* Device name for 0x1008 *)
	OBJ_HWVer_String : POINTER TO STRING; (* Hardware version for 0x1009 *)
	OBJ_SWVer_String : POINTER TO STRING; (* Software version for 0x100A *)

	HeartBeat_Prod_TM : TIME := t#1s; (* Producer Heartbeat time, 0x1017 *)
END_VAR
VAR_OUTPUT
END_VAR
VAR
	Dn_Buffer : ARRAY[0..3] OF BYTE; (* buffer for downloading of objects *)
(*	Up_Buffer : ARRAY[0..3] OF BYTE; (* buffer for uploading of objects *) *)
END_VAR
(* @END_DECLARATION := '0' *)
IF SDOSVR_PROC <> 0 THEN
	(* on call, SDO Processor should have a request dispatch, check if it matches any of our objects *)
	CASE SDOSVR_PROC^.Request_RESULT OF
	2:
		(* Upload or READ requests *)
		CASE SDOSVR_PROC^.Request_OBJ OF
		16#1000:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* transfer device profile and features and submit to processor via expedited response *)
				SDOSVR_PROC^.CANSDO_DATA[4] := WORD_TO_BYTE( DeviceType_Profile );
				SDOSVR_PROC^.CANSDO_DATA[5] := WORD_TO_BYTE( SHR( DeviceType_Profile, 8 ) );
				SDOSVR_PROC^.CANSDO_DATA[6] := WORD_TO_BYTE( DeviceType_Features );
				SDOSVR_PROC^.CANSDO_DATA[7] := WORD_TO_BYTE( SHR( DeviceType_Features, 8 ) );
				SDOSVR_PROC^.TX_EXP_UP_RESP( Response_BUFFER_LEN:=4 );
			END_IF
		16#1008:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* send device name string, if one is set *)
				IF OBJ_DevName_String <> 0 THEN
					SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_DevName_String^ ), Response_BUFFER_PTR:=OBJ_DevName_String );
				END_IF
			END_IF
		16#1009:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* send hw version string, if one is set *)
				IF OBJ_HWVer_String <> 0 THEN
					SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_HWVer_String^ ), Response_BUFFER_PTR:=OBJ_HWVer_String );
				END_IF
			END_IF
		16#100A:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* send sw version string, if one is set *)
				IF OBJ_SWVer_String <> 0 THEN
					SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_SWVer_String^ ), Response_BUFFER_PTR:=OBJ_SWVer_String );
				END_IF
			END_IF
		16#1017:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* upload request, deposit in SDO processor buffer and submit expedited response *)
				SDOSVR_PROC^.CANSDO_DATA[4] := DWORD_TO_BYTE( MIN( TIME_TO_DWORD( HeartBeat_Prod_TM ), 65535 ) AND 16#FF );
				SDOSVR_PROC^.CANSDO_DATA[5] := DWORD_TO_BYTE( SHR( MIN( TIME_TO_DWORD( HeartBeat_Prod_TM ), 65535 ), 8 ) );
				SDOSVR_PROC^.CANSDO_DATA[6] := SDOSVR_PROC^.CANSDO_DATA[7] := 0;
				SDOSVR_PROC^.TX_EXP_UP_RESP( Response_BUFFER_LEN:=2 );
			END_IF
		END_CASE

	3:
		(* download (WRITE) request notification *)
		CASE SDOSVR_PROC^.Request_OBJ OF
		16#1000,
		16#1008,
		16#1009,
		16#100A:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* client tried to download, object is read only *)
				SDOSVR_PROC^.TX_ERR_R_ONLY;
			END_IF
		16#1017:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSE
				(* download request, if length known, and not right, reject it, else accept it to our buffer *)
				IF SEL( SDOSVR_PROC^.Request_LEN_KNOWN, SDOSVR_PROC^.Request_LEN >= 2, SDOSVR_PROC^.Request_LEN = 2 ) THEN
					IF SDOSVR_PROC^.Request_EXP THEN
						(* with request expedited we'll just handle it here *)
						HeartBeat_Prod_TM := DWORD_TO_TIME( SHL( BYTE_TO_DWORD( SDOSVR_PROC^.CANSDO_DATA[5] ), 8 ) +  SDOSVR_PROC^.CANSDO_DATA[4] );
						SDOSVR_PROC^.TX_ACK_EXP_DN; (* acknowledge the download request *)
					ELSE
						(* requester didn't expedite but the length seems within reason so allow the request to CONTINUE *)
						SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=2, Response_BUFFER_PTR:=ADR( Dn_Buffer ) );
					END_IF
				ELSE
					SDOSVR_PROC^.TX_ERR_BAD_SIZE; (* incorrect size for object *)
				END_IF
			END_IF
		END_CASE

	4:
		(* download completion notification *)
		CASE SDOSVR_PROC^.Request_OBJ OF
		16#1017:
			(* download completed, save value, if right number of bytes received, not overrunning our buffer *)
			IF SDOSVR_PROC^.Request_LEN = 2 AND NOT SDOSVR_PROC^.Request_BUFFEROVERRUN THEN
				(* convert from little endian to big endian and store in register *)
				HeartBeat_Prod_TM := DWORD_TO_TIME( SHL( BYTE_TO_DWORD( Dn_Buffer[1] ), 8 ) +  Dn_Buffer[0] );
			ELSE
				SDOSVR_PROC^.TX_ERR_BAD_SIZE; (* incorrect size for object *)
			END_IF
		END_CASE

	END_CASE


(*	this is an alternate coding method ...
	(* only process when RESULT is 2, 3 or 4 *)
	IF MUX( SDOSVR_PROC^.Request_RESULT, FALSE, FALSE, TRUE, TRUE, TRUE, FALSE ) THEN

		CASE SDOSVR_PROC^.Request_OBJ OF
		16#1000:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSIF SDOSVR_PROC^.Request_RESULT = 3 THEN
				(* client tried to download, object is read only *)
				SDOSVR_PROC^.TX_ERR_R_ONLY;
			ELSE
				(* transfer device profile and features and submit to processor via expedited response *)
				SDOSVR_PROC^.CANSDO_DATA[4] := WORD_TO_BYTE( DeviceType_Profile );
				SDOSVR_PROC^.CANSDO_DATA[5] := WORD_TO_BYTE( SHR( DeviceType_Profile, 8 ) );
				SDOSVR_PROC^.CANSDO_DATA[6] := WORD_TO_BYTE( DeviceType_Features );
				SDOSVR_PROC^.CANSDO_DATA[7] := WORD_TO_BYTE( SHR( DeviceType_Features, 8 ) );
				SDOSVR_PROC^.TX_EXP_UP_RESP( Response_BUFFER_LEN:=4 );
			END_IF
		16#1008:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSIF SDOSVR_PROC^.Request_RESULT = 3 THEN
				(* client tried to download, object is read only *)
				SDOSVR_PROC^.TX_ERR_R_ONLY;
			ELSIF OBJ_DevName_String <> 0 THEN
				SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_DevName_String^ ), Response_BUFFER_PTR:=OBJ_DevName_String );
			END_IF
		16#1009:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSIF SDOSVR_PROC^.Request_RESULT = 3 THEN
				(* client tried to download, object is read only *)
				SDOSVR_PROC^.TX_ERR_R_ONLY;
			ELSIF OBJ_HWVer_String <> 0 THEN
				SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_HWVer_String^ ), Response_BUFFER_PTR:=OBJ_HWVer_String );
			END_IF
		16#100A:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSIF SDOSVR_PROC^.Request_RESULT = 3 THEN
				(* client tried to download, object is read only *)
				SDOSVR_PROC^.TX_ERR_R_ONLY;
			ELSIF OBJ_SWVer_String <> 0 THEN
				SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=LEN( OBJ_SWVer_String^ ), Response_BUFFER_PTR:=OBJ_SWVer_String );
			END_IF
		16#1017:
			IF SDOSVR_PROC^.Request_SIDX <> 0 THEN
				(* object is wholly contained in SIDX 0 *)
				SDOSVR_PROC^.TX_ERR_INV_SIDX;
			ELSIF SDOSVR_PROC^.Request_RESULT = 3 THEN
				(* download request, if length known, and not right, reject it, else accept it to our buffer *)
				IF SEL( SDOSVR_PROC^.Request_LEN_KNOWN, SDOSVR_PROC^.Request_LEN >= 2, SDOSVR_PROC^.Request_LEN = 2 ) THEN
					IF SDOSVR_PROC^.Request_EXP THEN
						HeartBeat_Prod_TM := DWORD_TO_TIME( SHL( BYTE_TO_DWORD( SDOSVR_PROC^.CANSDO_DATA[5] ), 8 ) +  SDOSVR_PROC^.CANSDO_DATA[4] );
						SDOSVR_PROC^.TX_ACK_EXP_DN; (* acknowledge the download request *)
					ELSE
						(* requester didn't expedite but the length seems within reason so allow the request to CONTINUE *)
						SDOSVR_PROC^.DispatchResponse( Response_BUFFER_LEN:=2, Response_BUFFER_PTR:=ADR( Dn_Buffer ) );
					END_IF
				ELSE
					SDOSVR_PROC^.TX_ERR_BAD_SIZE; (* incorrect size for object *)
				END_IF
			ELSIF SDOSVR_PROC^.Request_RESULT = 4 THEN
				(* download completed, save value, if right number of bytes received, not overrunning our buffer *)
				IF SDOSVR_PROC^.Request_LEN = 2 AND NOT SDOSVR_PROC^.Request_BUFFEROVERRUN THEN
					(* convert from little endian to big endian and store in register *)
					HeartBeat_Prod_TM := DWORD_TO_TIME( SHL( BYTE_TO_DWORD( Dn_Buffer[1] ), 8 ) +  Dn_Buffer[0] );
				ELSE
					SDOSVR_PROC^.TX_ERR_BAD_SIZE; (* incorrect size for object *)
				END_IF
			ELSIF SDOSVR_PROC^.Request_RESULT = 2 THEN
				(* upload request, deposit in SDO processor buffer and submit expedited response *)
				SDOSVR_PROC^.CANSDO_DATA[4] := DWORD_TO_BYTE( MIN( TIME_TO_DWORD( HeartBeat_Prod_TM ), 65535 ) AND 16#FF );
				SDOSVR_PROC^.CANSDO_DATA[5] := DWORD_TO_BYTE( SHR( MIN( TIME_TO_DWORD( HeartBeat_Prod_TM ), 65535 ), 8 ) );
				SDOSVR_PROC^.CANSDO_DATA[6] := SDOSVR_PROC^.CANSDO_DATA[7] := 0;
				SDOSVR_PROC^.TX_EXP_UP_RESP( Response_BUFFER_LEN:=2 );
			END_IF
		END_CASE
 	END_IF
*)
END_IF
END_FUNCTION_BLOCK
