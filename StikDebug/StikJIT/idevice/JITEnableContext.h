//
//  JITEnableContext.h
//  StikJIT
//
//  Created by s s on 2025/3/28.
//
@import Foundation;
@import UIKit;
#include "idevice.h"
#include "heartbeat.h"
#include "mount.h"

typedef void (^HeartbeatCompletionHandler)(int result, NSString *message);
typedef void (^LogFuncC)(const char* message, ...);
typedef void (^LogFunc)(NSString *message);
typedef void (^SyslogLineHandler)(NSString *line);
typedef void (^SyslogErrorHandler)(NSError *error);

@interface JITEnableContext : NSObject {
    // process
    @protected dispatch_queue_t processInspectorQueue;

    // RemotePairing tunnel (adapter + RSD handshake). Cached and reused
    // across all RSD-based services (mount, etc) once established, matching
    // upstream StikDebug's ensureTunnel()/startTunnel() design. Replaces the
    // old lockdownd-VPN IdeviceProviderHandle, which iOS 26.4+ blocks.
    @protected AdapterHandle*      g_adapter;
    @protected RsdHandshakeHandle* g_handshake;

    // syslog
    @protected dispatch_queue_t syslogQueue;
    @protected BOOL syslogStreaming;
    @protected SyslogRelayClientHandle *syslogClient;
    @protected SyslogLineHandler syslogLineHandler;
    @protected SyslogErrorHandler syslogErrorHandler;
    
    // ideviceInfo
    @protected LockdowndClientHandle *   g_client;
}
@property (class, readonly)JITEnableContext* shared;
- (RpPairingFileHandle*)getPairingFileWithError:(NSError**)error;
- (AdapterHandle*)getTunnelAdapterHandle;
- (RsdHandshakeHandle*)getTunnelHandshakeHandle;
- (BOOL)ensureHeartbeatWithError:(NSError**)err;
- (BOOL)startHeartbeat:(NSError**)err;

@end

@interface JITEnableContext(DDI)
- (NSUInteger)getMountedDeviceCount:(NSError**)error __attribute__((swift_error(zero_result)));
- (NSInteger)mountPersonalDDIWithImagePath:(NSString*)imagePath trustcachePath:(NSString*)trustcachePath manifestPath:(NSString*)manifestPath error:(NSError**)error __attribute__((swift_error(nonzero_result)));
@end
