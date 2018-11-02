# CANopen SDO Server Protocol Processor in IEC 61131-3

This repository will hold a protocol processor written in IEC 61131-3 structured text for the CANopen SDO protocol.

It will handle upload and download of both expedited and segmented transfers.  It can handle up to three simultaneous transfers; 1 segmented upload, 1 segmented download, and 1 expedited transfer in either direction.  It can handle an enumeration interface (broadcast request) if provided by the CAN interface pre-processor, which mutes certain error responses.

You must supply a CAN interface pre-processor (receive & transmit), as the SDO Server Protocol Processor is implemented to be independent of CAN interface implementations.  You must also provide the dictionary object handling post-processor.  This increases flexibility and benefits code reuse.  An example is included within this repository.

This implementation is based on a CoDeSys V2.3 environment.  It has been tested on IFM Classic and NT hardware.  It has been utilized in an application which involved multiple separate dictionary object post-processors and multiple CAN interface implementations on a single controller, including multiple instances of the SDO Server Protocol Processor.

-- -
## SDO SVR Protocol Processor.ST
### FB_SDOSVR_PROC
This is the primary SDO Server processing core, and can be re-used with nearly any CAN interface implementation and dictionary object implementation.

Please see the declaration of FB_SDOSVR_PROC for further implementation details.

[more information forthcoming regarding public actions of FB_SDOSVR_PROC]

-- -
## SDO SVR CAN Preprocessor IFM NT.ST
This is an example CAN preprocessor for use with IFM NT hardware.  It includes a function block implementation for enumeration as well.  The action `InitSvr()` should be called for initialization of the function block `FB_SDOSVR_CAN_NT`.

### FB_SDOSVR_CAN_NT
This function block includes an instance of FB_SDOSVR_PROC, and is the primary application interface to the SDO server for a given CAN implementation, in this case, for IFM NT hardware.  The instance of FB_SDOSVR_PROC (SDOSVR_PROC) is accessible to the application, as dictionary object processing will require direct interaction with the SDO server core, and not with the CAN preprocessor.

#### FB_SDOSVR_CAN_NT.InitSvr Action
An action called during application initialization to initialize CAN implementation objects RX_CAN and TX_CAN with the standard calculated COB-ID's for SDO Request and Response objects, and other needed items such as the CAN channel.  The IFM NT CAN implementation does permit the changing of COB-ID's of the RX objects after the first initialization, but this is not fully demonstrated here.

### FB_FB_SDOSVR_CAN_NT_ENUM_RX
This function block handles just the receiving of enumeration requests from the CAN implementation.  See the application implementation hint below for how it is used.

### Application Example
In general this is how the function block `FB_SDOSVR_CAN_NT` (along with `FB_SDOSVR_CAN_NT_ENUM_RX` for enumeration support) would be utilized in the application:

```Pascal
VAR
	SDO_CAN1 : FB_SDOSVR_CAN_NT := ( CHANNEL:=1 ); (* SDO processing engine *)
	SDO_CAN1_ENUM : FB_SDOSVR_CAN_NT_ENUM_RX := ( CHANNEL:=1 ); (* SDO processing engine enumeration receiver for all nodes on CAN 1 *)
	SDO_CAN1_STDOBJ : FB_SDOSVR_STDOBJS; (* handle standard objects for SVR on CAN1 *)
END_VAR

SDO_CAN1.InitSvr( NodeID_Init:=16#30, Enum_RX:=ADR( SDO_CAN1_ENUM ) ); (* initialize *)
```
```Pascal
(* Process SDO requests for ID 0x30 *)
REPEAT
	SDO_CAN1_ENUM;
	IF SDO_CAN1_ENUM.AVAILABLE THEN
		SDO_CAN1.Enum_RX_Flag := TRUE;  (* flag an enumeration request on the only node on CAN1 *)
	END_IF

	REPEAT
		SDO_CAN1;
		IF NOT SDO_CAN1.TX_BUFFER_FULL THEN
			(* check for, and dispatch requests through the OBJ handlers *)
			IF SDO_CAN1.SDOSVR_PROC.Request_RESULT > 1 THEN
				SDO_CAN1_STDOBJ;    (* Standard objects *)
				RAST_ReqProc_ID30;  (* custom OEM objects 0x2000-0x5FFF *)
				RAST_STRG_ID30;     (* handle auto storage events *)
			END_IF
		END_IF
	UNTIL SEL( SDO_CAN1.TX_BUFFER_FULL, SDO_CAN1.RX_BUFFER_EMPTY AND NOT (SDO_CAN1.SDOSVR_PROC.CANSDO_TX OR 
	  SDO_CAN1.Enum_RX_Flag) AND SDO_CAN1.SDOSVR_PROC.Request_RESULT <= 1, TRUE )
	END_REPEAT
UNTIL NOT SDO_CAN1_ENUM.AVAILABLE
END_REPEAT
```

Note that enumeration requests will be processed last, and with the lowest priority, and such if the TX buffer was to become full before getting to the enumeration request, it will be thrown away.  Also note, that the enumeration request processing would be more involved if there were multiple virtual nodes in the application that needed notified of the enumeration request, as usually the processing of the SDO Server in other virtual nodes may occur seperately.

See the declarations for further details regarding the implementation of `FB_SDOSVR_CAN_NT` and  `FB_SDOSVR_CAN_NT_ENUM_RX`.

-- -
## SDO SVR Standard Objects.ST
A yet to come example dictionary object post-processor showing handling of an dictionary object request from the SDO server.

-- -
## What is an enumeration request?
An enumeration request is not a standard CANopen function.  It is a concept where by devices (nodes) that support such a function can be identified rapidly with a single request.  CANopen COB-ID 0x600 is utilized, the contents of which forms a standard SDO request, preferably a read object request for a common object (such as 0x1000.00 aka Device Type).  All nodes that support the function respond back on their respective response COB-ID.  Generally enumeration requests are low frequency events usually associated with discovery or diagnosis.  The included example CAN pre-processor restricts enumeration requests to only SDO requests that are an initial request, however, there is no restriction that the object requested cannot be an object that requires segmented transfer, but the remainder of the segmented transfer will be conducted via the standard request/response COB-ID's.  Because of the complexity of segmented transfers, it is generally recommended to not use such objects in enumeration requests.

-- -
Additional notes:
1. Please see the repository [TOS_ST](https://github.com/msftrncs/TOS_ST) for the function block TOS.  It is a timer function block like the standard function block TP, but with RESTART(RS) and CLEAR(C) functionality via actions.  It is used for handling activity time-out.
1. Non IEC actions are used by this protocol processor, both for private and for public purposes.  Support for this could vary.
1. More information will be coming for examples as to how to construct pre-processor/post-processor and dictionary object handlers and interface them with the protocol processor, and an application.

Change Log:
- 2018-11-02 - Chk_Timers was removed from the example CAN preprocessor, utilizing a different scheme to make sure the transfer timers are checked.  CLEAR_TX_REQ in the protocol processor automatically performs clean up, and this has been accounted for in the example preprocessor.
