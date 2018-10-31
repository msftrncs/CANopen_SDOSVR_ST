# CANopen SDO Server Protocol Processor in IEC 61131-3

This repository will hold a protocol processor written in IEC 61131-3 structured text for the CANopen SDO protocol.

It will handle upload and download of both expedited and segmented transfers.  It can handle up to three simultaneous transfers; 1 segmented upload, 1 segmented download, and 1 expedited transfer in either direction.  It can handle an enumeration interface (broadcast request) if provided by the CAN interface pre-processor, which mutes certain error responses.

You must supply a CAN interface pre-processor (receive) and post-processor (transmit), as the SDO Server Protocol Processor is implemented to be independent of CAN interface implementations.  You must also provide the dictionary object handling post-processor.  This increases flexibility and benefits code reuse.

This implementation is based on a CoDeSys V2.3 environment.  It has been tested on IFM Classic and NT hardware.  It has been utilized in an application which involved multiple separate dictionary object post-processors and multiple CAN interface implementations on a single controller, including multiple instances of the SDO Server Protocol Processor.

Additional notes:
1. Please see the repository [TOS_ST](https://github.com/msftrncs/TOS_ST) for the function block TOS.  It is a timer function block like the standard function block TP, but with RESTART(RS) and CLEAR(C) functionality via actions.  It is used for handling activity time-out.
1. Non IEC actions are used by this protocol processor, both for private and for public purposes.  Support for this could vary.
1. More information will be coming for examples as to how to construct pre-processor/post-processor and dictionary object handlers and interface them with the protocol processor, and an application.
