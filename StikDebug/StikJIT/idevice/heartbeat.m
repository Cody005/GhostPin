// Jackson Coxson
// heartbeat.c

#include "idevice.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/_types/_u_int64_t.h>
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include "heartbeat.h"
#include <pthread.h>
@import Foundation;

int globalHeartbeatToken = 0;
NSDate* lastHeartbeatDate = nil;

// RemotePairing (RPPairing) service port. Unlike the old CoreDeviceProxy
// path (lockdownd, port 62078), this connects directly to the on-device
// RemotePairing listener, which is not subject to iOS 26.4+'s lockdownd
// VPN-netmask restriction on utun connections.
#define RPPAIRING_PORT 49152

// Writes directly to stderr (visible via `devicectl device process launch
// --console` or an attached debugger), unlike NSLog which routes through
// the unified logging system and may not be visible over a remote console.
#define GP_LOG(fmt, ...) do { fprintf(stderr, "[GhostPin] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

// Establishes the RemotePairing tunnel exactly once (no continuous
// marco/polo keep-alive loop needed for RPPairing sessions, unlike the old
// lockdownd heartbeat protocol). Callers only invoke this when there is no
// cached tunnel yet (see -[JITEnableContext ensureHeartbeatWithError:]), and
// the resulting adapter/handshake are cached and reused by all subsequent
// RSD-based calls (mount, etc) until the app restarts or the tunnel errors.
void startHeartbeat(RpPairingFileHandle* pairing_file, AdapterHandle** adapter, RsdHandshakeHandle** handshake, int heartbeatToken, HeartbeatCompletionHandlerC completion) {
    IdeviceFfiError* err = nil;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(RPPAIRING_PORT);

    NSString* deviceIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"customTargetIP"];
    inet_pton(AF_INET, (deviceIP && deviceIP.length > 0) ? [deviceIP UTF8String] : "10.7.0.1", &addr.sin_addr);

    GP_LOG("startHeartbeat: creating RPPairing tunnel to %s:%d", (deviceIP && deviceIP.length > 0) ? [deviceIP UTF8String] : "10.7.0.1", RPPAIRING_PORT);
    AdapterHandle* newAdapter = NULL;
    RsdHandshakeHandle* newHandshake = NULL;
    err = tunnel_create_rppairing((struct sockaddr *)&addr,
                                  sizeof(addr),
                                  "GhostPinHeartbeat",
                                  pairing_file,
                                  NULL,
                                  NULL,
                                  &newAdapter,
                                  &newHandshake);
    // pairing_file is borrowed (not consumed) by tunnel_create_rppairing.
    rp_pairing_file_free(pairing_file);
    if (err != NULL) {
        GP_LOG("tunnel_create_rppairing FAILED: code=%d message=%s", err->code, err->message);
        completion(err->code, err->message);
        idevice_error_free(err);
        return;
    }
    GP_LOG("tunnel_create_rppairing succeeded");

    // Sanity-check the tunnel is actually usable before caching it.
    HeartbeatClientHandle *client = NULL;
    err = heartbeat_connect_rsd(newAdapter, newHandshake, &client);
    if (err != NULL) {
        GP_LOG("heartbeat_connect_rsd FAILED: code=%d message=%s", err->code, err->message);
        completion(err->code, err->message);
        rsd_handshake_free(newHandshake);
        adapter_free(newAdapter);
        idevice_error_free(err);
        return;
    }
    GP_LOG("heartbeat_connect_rsd succeeded");
    heartbeat_client_free(client);

    if (*handshake) { rsd_handshake_free(*handshake); }
    if (*adapter)   { adapter_free(*adapter); }
    *adapter   = newAdapter;
    *handshake = newHandshake;

    lastHeartbeatDate = [NSDate now];
    completion(0, "Tunnel connected");
}
