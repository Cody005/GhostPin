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

void startHeartbeat(IdevicePairingFile* pairing_file, IdeviceProviderHandle** provider, int heartbeatToken, HeartbeatCompletionHandlerC completion) {
    IdeviceProviderHandle* newProvider = *provider;
    IdeviceFfiError* err = nil;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(LOCKDOWN_PORT);

    NSString* deviceIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"customTargetIP"];
    inet_pton(AF_INET, (deviceIP && deviceIP.length > 0) ? [deviceIP UTF8String] : "10.7.0.1", &addr.sin_addr);

    err = idevice_tcp_provider_new((struct sockaddr *)&addr, pairing_file,
                                   "ExampleProvider", &newProvider);
    if (err != NULL) {
        completion(err->code, err->message);
        idevice_pairing_file_free(pairing_file);
        idevice_error_free(err);
        return;
    }

    HeartbeatClientHandle *client = NULL;
    err = heartbeat_connect(newProvider, &client);
    if (err != NULL) {
        completion(err->code, err->message);
        idevice_provider_free(newProvider);
        idevice_error_free(err);
        return;
    }

    *provider = newProvider;

    bool completionCalled = false;
    u_int64_t current_interval = 15;

    while (1) {
        u_int64_t new_interval = 0;
        err = heartbeat_get_marco(client, current_interval, &new_interval);
        if (err != NULL) {
            if (!completionCalled) {
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);
            return;
        }

        // If a newer heartbeat thread has started, yield to it
        if (heartbeatToken != globalHeartbeatToken) {
            heartbeat_client_free(client);
            return;
        }

        current_interval = new_interval + 5;

        err = heartbeat_send_polo(client);
        if (err != NULL) {
            if (!completionCalled) {
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);
            return;
        }

        if (lastHeartbeatDate && [[NSDate now] timeIntervalSinceDate:lastHeartbeatDate] > current_interval) {
            lastHeartbeatDate = nil;
            return;
        }
        lastHeartbeatDate = [NSDate now];

        if (!completionCalled) {
            completion(0, "Heartbeat succeeded");
            completionCalled = true;
        }
    }
}
