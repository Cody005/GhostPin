//
//  JITEnableContext.m
//  StikJIT
//
//  Created by s s on 2025/3/28.
//
#import <pthread.h>
#import <os/lock.h>
#include "idevice.h"
#import "JITEnableContext.h"
#import "JITEnableContextInternal.h"
#import "heartbeat.h"
@import Foundation;
@import os.log;

static JITEnableContext* sharedJITContext = nil;

@implementation JITEnableContext {    
    int heartbeatToken;
    NSError* lastHeartbeatError;
    os_unfair_lock heartbeatLock;
    BOOL heartbeatRunning;
    dispatch_semaphore_t heartbeatSemaphore;
}

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedJITContext = [[JITEnableContext alloc] init];
    });
    return sharedJITContext;
}

- (instancetype)init {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL* logURL = [docPathUrl URLByAppendingPathComponent:@"idevice_log.txt"];
    idevice_init_logger(Info, Debug, (char*)logURL.path.UTF8String);
    syslogQueue = dispatch_queue_create("com.stik.syslogrelay.queue", DISPATCH_QUEUE_SERIAL);
    syslogStreaming = NO;
    syslogClient = NULL;
    dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    processInspectorQueue = dispatch_queue_create("com.stikdebug.processInspector", qosAttr);

    heartbeatToken = 0;
    heartbeatLock = OS_UNFAIR_LOCK_INIT;
    heartbeatRunning = NO;
    heartbeatSemaphore = NULL;
    lastHeartbeatError = nil;

    return self;
}

- (NSError*)errorWithStr:(NSString*)str code:(int)code {
    return [NSError errorWithDomain:@"StikJIT"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: str }];
}

- (LogFuncC)createCLogger:(LogFunc)logger {
    return ^(const char* format, ...) {
        va_list args;
        va_start(args, format);
        NSString* fmt = [NSString stringWithCString:format encoding:NSASCIIStringEncoding];
        NSString* message = [[NSString alloc] initWithFormat:fmt arguments:args];
        if (logger) {
            logger(message);
        }
        va_end(args);
    };
}

- (RpPairingFileHandle*)getPairingFileWithError:(NSError**)error {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL* pairingFileURL = [docPathUrl URLByAppendingPathComponent:@"pairingFile.plist"];

    if (![fm fileExistsAtPath:pairingFileURL.path]) {
        *error = [self errorWithStr:@"Pairing file not found!" code:-17];
        return nil;
    }

    RpPairingFileHandle* pairingFile = NULL;
    IdeviceFfiError* err = rp_pairing_file_read(pairingFileURL.fileSystemRepresentation, &pairingFile);
    if (err) {
        *error = [self errorWithStr:@"Failed to read pairing file!" code:err->code];
        idevice_error_free(err);
        return nil;
    }
    return pairingFile;
}

- (AdapterHandle*)getTunnelAdapterHandle {
    return g_adapter;
}

- (RsdHandshakeHandle*)getTunnelHandshakeHandle {
    return g_handshake;
}

// Establishes the RemotePairing tunnel exactly once and caches adapter +
// handshake for reuse by every RSD-based service (mount, etc). Unlike the
// old per-call lockdown-VPN reconnect, this mirrors upstream StikDebug's
// ensureTunnel()/startTunnel() — reconnecting on every call was causing
// mount-then-immediately-recheck races where the freshly mounted DDI wasn't
// visible yet on the brand new tunnel session.
- (BOOL)startHeartbeat:(NSError**)err {
    os_unfair_lock_lock(&heartbeatLock);

    if (heartbeatRunning) {
        dispatch_semaphore_t waitSemaphore = heartbeatSemaphore;
        os_unfair_lock_unlock(&heartbeatLock);

        if (waitSemaphore) {
            dispatch_semaphore_wait(waitSemaphore, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(waitSemaphore);
        }
        *err = lastHeartbeatError;
        return *err == nil;
    }

    heartbeatRunning = YES;
    heartbeatSemaphore = dispatch_semaphore_create(0);
    dispatch_semaphore_t completionSemaphore = heartbeatSemaphore;
    os_unfair_lock_unlock(&heartbeatLock);

    RpPairingFileHandle* pairingFile = [self getPairingFileWithError:err];
    if (*err) {
        os_unfair_lock_lock(&heartbeatLock);
        heartbeatRunning = NO;
        heartbeatSemaphore = NULL;
        os_unfair_lock_unlock(&heartbeatLock);
        dispatch_semaphore_signal(completionSemaphore);
        return NO;
    }

    globalHeartbeatToken++;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block bool completionCalled = false;
    __block NSError *blockError = nil;
    HeartbeatCompletionHandlerC Ccompletion = ^(int result, const char *message) {
        if (completionCalled) { return; }
        if (result != 0) {
            blockError = [self errorWithStr:[NSString stringWithCString:message encoding:NSASCIIStringEncoding] code:result];
            self->lastHeartbeatError = blockError;
        } else {
            self->lastHeartbeatError = nil;
        }
        completionCalled = true;
        dispatch_semaphore_signal(semaphore);
    };

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        startHeartbeat(pairingFile, &self->g_adapter, &self->g_handshake, globalHeartbeatToken, Ccompletion);
    });

    intptr_t isTimeout = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(5 * NSEC_PER_SEC)));
    if (isTimeout) {
        Ccompletion(-1, "Tunnel failed to connect in reasonable time.");
    }

    *err = blockError;

    os_unfair_lock_lock(&heartbeatLock);
    heartbeatRunning = NO;
    heartbeatSemaphore = NULL;
    os_unfair_lock_unlock(&heartbeatLock);
    dispatch_semaphore_signal(completionSemaphore);

    return *err == nil;
}

- (BOOL)ensureHeartbeatWithError:(NSError**)err {
    // Reuse the cached tunnel if we already have one — do NOT reconnect on
    // every call. Reconnecting per-call was the root cause of the DDI mount
    // succeeding but immediately reading back as "not mounted": each check
    // was happening on a brand new tunnel session.
    if (g_adapter && g_handshake) {
        return YES;
    }
    return [self startHeartbeat:err];
}

- (void)dealloc {
    if (g_handshake) {
        rsd_handshake_free(g_handshake);
    }
    if (g_adapter) {
        adapter_free(g_adapter);
    }
}

@end
