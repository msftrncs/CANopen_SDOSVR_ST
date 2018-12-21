

(* @NESTEDCOMMENTS := 'Yes' *)
(* @PATH := '\/SDO Server' *)
(* @OBJECTFLAGS := '0, 8' *)
(* @SYMFILEFLAGS := '2048' *)
FUNCTION_BLOCK FB_SDOSVR_CAN_NT (* SDO Server Interface for IFM NT hardware *)
VAR_INPUT
	CHANNEL : BYTE; (* CAN channel as required by CAN RX/TX *)
	NodeID_Init : USINT; (* Node ID to Initialize *)
	Enum_RX : POINTER TO FB_SDOSVR_CAN_NT_ENUM_RX; (* optional enumeration request receiver block *)
	Enum_RX_Flag : BOOL; (* Enumeration request to receive and process? *)
	SDOSVR_PROC : FB_SDOSVR_PROC; (* instance of an SDO server processor *)
END_VAR
VAR_OUTPUT
	INIT : BOOL := TRUE; (* block needs initialized? *)
	NodeID_Set : USINT; (* Node ID currently set *)
	TX_BUFFER_FULL : BOOL; (* TX_BUFFER was full, TX couldn't be made, need to wait for more room *)
	RX_BUFFER_EMPTY : BOOL; (* RX_BUFFER was empty, no need for further processing *)
END_VAR
VAR
	RX_CAN : CAN_RX_ENH_FIFO := ( ENABLE:=TRUE, ID_MASK:=16#7FF ); (* IFM NT CAN receive block *)
	TX_CAN : CAN_TX_ENH := ( ENABLE:=TRUE ); (* IFM NT CAN transmit block *)
	(* V1-1 removed Chk_Timers, revised scheme doesn't require the flag *)
END_VAR
(* @END_DECLARATION := '0' *)
IF NOT INIT THEN
	REPEAT
		(* check if action left with pending transmit *)
		IF SDOSVR_PROC.CANSDO_TX THEN
			TX_CAN( DATA:=SDOSVR_PROC.CANSDO_DATA, DATALENGTHCODE:=SDOSVR_PROC.CANSDO_DLC );
			TX_BUFFER_FULL := TX_CAN.RESULT = 250; (* track if TX FIFO is full *)
			IF NOT TX_BUFFER_FULL THEN
				SDOSVR_PROC.CLEAR_TX_REQ(); (* clear TX flag and clean up previous request results or pending actions *)
			ELSIF Enum_RX_Flag THEN (* added 2018-06-19 CMM, moved to TX section 2018-11-02 CMM *)
				(* Enumeration request was pending, but with no way to respond to it, we must abandon it *)
				Enum_RX_Flag := FALSE;
			END_IF
		ELSE
			SDOSVR_PROC.CleanUp(); (* clean up any previous request results and pending actions, sending INV_OBJ if required (generating another transmit) *)
		END_IF

		(* if a pending transmit is still pending, we cannot process any received messages, as they may cause transmission requests *)
		IF SEL( SDOSVR_PROC.CANSDO_TX, SDOSVR_PROC.Request_RESULT <= 1, FALSE ) THEN
			(* all seems to be good, check RX, and if any, attempt to process *)
			RX_CAN();
			RX_BUFFER_EMPTY := NOT RX_CAN.MORE_DATA_AVAILABLE;
			IF RX_CAN.RESULT = 1 OR RX_CAN.RESULT = 250 THEN
				SDOSVR_PROC( CANSDO_DATA:=RX_CAN.DATA, CANSDO_DLC:=RX_CAN.DATALENGTHCOUNT );
			ELSIF Enum_RX_Flag THEN
				IF Enum_RX <> 0 THEN
					(* process enumeration request *)
					SDOSVR_PROC( CANSDO_DATA:=Enum_RX^.RX_CAN.DATA, CANSDO_DLC:=Enum_RX^.RX_CAN.DATALENGTHCOUNT, CANSDO_IsEnum:=TRUE );
				END_IF
				Enum_RX_Flag := FALSE;
			END_IF
			IF SEL( SDOSVR_PROC.Request_RESULT = 1, FALSE, SEL( SDOSVR_PROC.CANSDO_TX, RX_BUFFER_EMPTY, FALSE ) ) THEN
				(* SDO service has active transfers, but is presently idle, check transfer timers *)
				SDOSVR_PROC.ChkTimers(); (* need to process timers, aborting transfers if timers have expired *)
			END_IF
		END_IF

	(* as long as TX FIFO isn't full and SDO processor is not pending a dispatch, if SDO processor still pending a TX OR CAN buffer has more data, repeat loop in attempt to clear it *)
	UNTIL SEL( TX_BUFFER_FULL, SEL( SDOSVR_PROC.Request_RESULT > 1, NOT (SDOSVR_PROC.CANSDO_TX OR Enum_RX_Flag) AND RX_BUFFER_EMPTY, TRUE ), TRUE )
	END_REPEAT
ELSE
	TX_BUFFER_FULL := TRUE; (* we are not initialized, so the TX buffer is considered full *)
END_IF
END_FUNCTION_BLOCK
ACTION	InitSvr:
(* Initialize server, should cancel any pending operations, though not neccessary *)
RX_CAN.CHANNEL := TX_CAN.CHANNEL := CHANNEL; (* set which NT channel to operate on *)
NodeID_Set := MIN( NodeID_Init, 127 ); (* restrict range of node ID's *)
RX_CAN.ID := 16#600 + NodeID_Set; (* specify desired SDO request ID *)
TX_CAN.ID := 16#580 + NodeID_Set; (* specify desired SDO response ID *)
Enum_RX_Flag := SDOSVR_PROC.CANSDO_IsEnum := FALSE; (* clarifying startup condition *)
INIT := FALSE; (* done initialized *)

END_ACTION




(* @NESTEDCOMMENTS := 'Yes' *)
(* @PATH := '\/SDO Server' *)
(* @OBJECTFLAGS := '0, 8' *)
(* @SYMFILEFLAGS := '2048' *)
FUNCTION_BLOCK FB_SDOSVR_CAN_NT_ENUM_RX (* SDO Server Enumeration Interface for IFM NT Hardware *)
VAR_INPUT
	CHANNEL : BYTE; (* CAN channel as required by CAN RX/TX *)
END_VAR
VAR_OUTPUT
	INIT : BOOL := TRUE; (* block needs initialized? *)
	AVAILABLE : BOOL; (* request is available in RX_CAN *)
END_VAR
VAR
	RX_CAN : CAN_RX_ENH_FIFO := ( ENABLE:=TRUE, ID_MASK:=16#7FF, ID:=16#600 ); (* IFM NT CAN receive block *)
END_VAR

(* @END_DECLARATION := '0' *)
(* receives SDO requests on a broadcast basis for enumeration of nodes.

This works by using COB_ID 0x600 as a broadcast SDO request message.  Generally the request will be for an upload, and the response will be expedited, keeping the 
process simple.  Request messages will only be accepted on this broadcast COB-ID that have an Initiate Upload or Initiate Download CCS value.

If the application supports mulitple nodes, this one instance must have its results processed by all nodes.   A response to a broadcast request will always be from
the node's response COB-ID.  If a response or request is not expedited, further interaction (segmented transfers and acknowledgements) between the requestor and this
node will occur as standard COB-ID messages, as the requester will need to be able to individually react to each node that responded.

Broadcast requests could interfere with ongoing responses to normal requests, especially if they do not generate an expedited response.  Broadcast requests would
usually be limited to devices that need to query available nodes that support a certain limited-use function, and thus only the needed objects for such means should
be available to broadcast requests.

The error responses, INV_OBJ, INV_SIDX and BAD_CMD will not sent in response to a broadcast request.

Application must service this block to retrieve request messages, and when indicated, utilize the enumeration request process action of each node's server block.

Requests will only be able to be processed by the individual SDO servers when they are not pending a TX (ie, TX buffer is full) so attempting to submit a request
will cause an attempt to flush any pending TX operation, and if unable to secure room in the TX buffer, the request will be ignored by the respective server.

For this to work, the node Server Instance needs a pointer to this block to retrieve the request message.  The server SDO processor block must be told that it
is processing a enumeration request, possibly having a specific enumeration action, so that it knows not to produce generic error responses to the request.  The
indication of an enumeration request can also be later used when dispatching the request so that dispatching can be limited to a set of objects

*)

IF INIT THEN
	RX_CAN.CHANNEL := CHANNEL;
	INIT := FALSE;
END_IF

REPEAT
	RX_CAN();
	(* only accept request messages with at least 4 data bytes, where CCS either 1 or 2 *)
	AVAILABLE := SEL( RX_CAN.RESULT = 1 OR RX_CAN.RESULT = 250, FALSE, SEL( RX_CAN.DATALENGTHCOUNT >= 4, FALSE, MUX( MIN( SHR( RX_CAN.DATA[0], 5 ), 3 ), FALSE, TRUE, TRUE, FALSE ) ) );

UNTIL SEL( AVAILABLE, NOT RX_CAN.MORE_DATA_AVAILABLE, TRUE )
END_REPEAT

END_FUNCTION_BLOCK
