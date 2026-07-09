//
//  heartbeat.h
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

// heartbeat.h
#ifndef HEARTBEAT_H
#define HEARTBEAT_H
#include "idevice.h"
@import Foundation;

typedef void (^HeartbeatCompletionHandlerC)(int result, const char *message);
typedef void (^LogFuncC)(const char* message, ...);

extern int globalHeartbeatToken;
extern NSDate* lastHeartbeatDate;

void startHeartbeat(RpPairingFileHandle* pairing_file, AdapterHandle** adapter, RsdHandshakeHandle** handshake, int heartbeatToken, HeartbeatCompletionHandlerC completion);
#endif /* HEARTBEAT_H */
