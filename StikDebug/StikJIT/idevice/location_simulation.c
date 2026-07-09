//
//  location_simulation.c
//  StikDebug
//
//  Created by Stephen on 8/3/25.
//

#include "location_simulation.h"
#include "idevice.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

static RpPairingFileHandle       *g_pairing       = NULL;
static AdapterHandle             *g_adapter       = NULL;
static RsdHandshakeHandle        *g_handshake     = NULL;
static RemoteServerHandle        *g_remote_server = NULL;
static LocationSimulationHandle  *g_location_sim  = NULL;
static atomic_bool               g_stopping       = ATOMIC_VAR_INIT(false);

// RemotePairing (RPPairing) service port. Unlike the old CoreDeviceProxy
// path (lockdownd, port 62078), this connects directly to the on-device
// RemotePairing listener, which is not subject to iOS 26.4+'s lockdownd
// VPN-netmask restriction on utun connections.
#define RPPAIRING_PORT 49152

#define GP_LOG(fmt, ...) do { fprintf(stderr, "[GhostPin] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

static void cleanup_all(void) {
    if (g_location_sim)  { location_simulation_free(g_location_sim);    g_location_sim  = NULL; }
    if (g_remote_server) { remote_server_free(g_remote_server);         g_remote_server = NULL; }
    if (g_handshake)     { rsd_handshake_free(g_handshake);             g_handshake     = NULL; }
    if (g_adapter)       { adapter_free(g_adapter);                     g_adapter       = NULL; }
    if (g_pairing)       { rp_pairing_file_free(g_pairing);             g_pairing       = NULL; }
}

void cancel_simulation(void) {
    // ONLY set the flag. Never touch handles here — they are owned exclusively
    // by the serial locationQueue. simulate_location checks this flag between
    // every blocking step and does its own cleanup when it sees it set.
    atomic_store(&g_stopping, true);
}

void start_simulation(void) {
    // Reset the stop flag before beginning a new simulation session.
    // Must be called on the serial locationQueue before simulate_location.
    atomic_store(&g_stopping, false);
}

#define BAIL_IF_STOPPING() \
    if (atomic_load(&g_stopping)) { cleanup_all(); return IPA_ERR_CANCELLED; }

int simulate_location(const char *device_ip,
                      double latitude,
                      double longitude,
                      const char *pairing_file)
{
    IdeviceFfiError *err = NULL;

    if (g_location_sim) {
        BAIL_IF_STOPPING();
        if ((err = location_simulation_set(g_location_sim, latitude, longitude))) {
            idevice_error_free(err);
            cleanup_all();
        } else {
            return IPA_OK;
        }
    }

    BAIL_IF_STOPPING();
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_port   = htons(RPPAIRING_PORT) };
    if (inet_pton(AF_INET, device_ip, &addr.sin_addr) != 1) {
        return IPA_ERR_INVALID_IP;
    }

    if (g_pairing) {
        rp_pairing_file_free(g_pairing);
        g_pairing = NULL;
    }

    BAIL_IF_STOPPING();
    if ((err = rp_pairing_file_read(pairing_file, &g_pairing))) {
        idevice_error_free(err);
        return IPA_ERR_PAIRING_READ;
    }

    // Connects directly over TCP to the device's RemotePairing (RPPairing)
    // listener via the LocalDevVPN loopback tunnel and performs the
    // pair-verify handshake, handing back a ready-to-use adapter + RSD
    // handshake in one call. This bypasses lockdownd entirely, so it is not
    // affected by iOS 26.4+'s VPN-netmask connection check.
    GP_LOG("simulate_location: creating RPPairing tunnel to %s:%d", device_ip, RPPAIRING_PORT);
    BAIL_IF_STOPPING();
    if ((err = tunnel_create_rppairing((struct sockaddr *)&addr,
                                       sizeof(addr),
                                       "GhostPinLocation",
                                       g_pairing,
                                       NULL,
                                       NULL,
                                       &g_adapter,
                                       &g_handshake)))
    {
        GP_LOG("simulate_location: tunnel_create_rppairing FAILED: code=%d message=%s", err->code, err->message);
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_RPPAIRING_TUNNEL;
    }
    GP_LOG("simulate_location: tunnel_create_rppairing succeeded");
    // pairing_file is borrowed (not consumed) by tunnel_create_rppairing,
    // unlike the old idevice_tcp_provider_new. Free it now; it's not needed
    // again this session.
    rp_pairing_file_free(g_pairing);
    g_pairing = NULL;

    BAIL_IF_STOPPING();
    if ((err = remote_server_connect_rsd(g_adapter,
                                         g_handshake,
                                         &g_remote_server)))
    {
        GP_LOG("simulate_location: remote_server_connect_rsd FAILED: code=%d message=%s", err->code, err->message);
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_REMOTE_SERVER;
    }
    GP_LOG("simulate_location: remote_server_connect_rsd succeeded");
    g_adapter   = NULL;
    g_handshake = NULL;

    BAIL_IF_STOPPING();
    if ((err = location_simulation_new(g_remote_server,
                                       &g_location_sim))) {
        GP_LOG("simulate_location: location_simulation_new FAILED: code=%d message=%s", err->code, err->message);
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_LOCATION_SIM;
    }
    g_remote_server = NULL;

    BAIL_IF_STOPPING();
    if ((err = location_simulation_set(g_location_sim,
                                       latitude,
                                       longitude))) {
        GP_LOG("simulate_location: location_simulation_set FAILED: code=%d message=%s", err->code, err->message);
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_LOCATION_SET;
    }

    GP_LOG("simulate_location: succeeded");
    return IPA_OK;
}

int clear_simulated_location(void)
{
    IdeviceFfiError *err = NULL;
    if (!g_location_sim) return IPA_ERR_LOCATION_CLEAR;

    err = location_simulation_clear(g_location_sim);
    cleanup_all();

    return err ? IPA_ERR_LOCATION_CLEAR : IPA_OK;
}
