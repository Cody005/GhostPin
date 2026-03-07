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

static IdevicePairingFile       *g_pairing       = NULL;
static IdeviceProviderHandle    *g_provider      = NULL;
static CoreDeviceProxyHandle    *g_core_device   = NULL;
static AdapterHandle            *g_adapter       = NULL;
static RsdHandshakeHandle       *g_handshake     = NULL;
static RemoteServerHandle       *g_remote_server = NULL;
static LocationSimulationHandle *g_location_sim  = NULL;
static atomic_bool              g_stopping       = ATOMIC_VAR_INIT(false);

static void cleanup_all(void) {
    if (g_location_sim)  { location_simulation_free(g_location_sim);    g_location_sim  = NULL; }
    if (g_remote_server) { remote_server_free(g_remote_server);         g_remote_server = NULL; }
    if (g_handshake)     { rsd_handshake_free(g_handshake);             g_handshake     = NULL; }
    if (g_adapter)       { adapter_free(g_adapter);                     g_adapter       = NULL; }
    if (g_core_device)   { core_device_proxy_free(g_core_device);       g_core_device   = NULL; }
    if (g_provider)      { idevice_provider_free(g_provider);           g_provider      = NULL; }
    if (g_pairing)       { idevice_pairing_file_free(g_pairing);        g_pairing       = NULL; }
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
                                .sin_port   = htons(LOCKDOWN_PORT) };
    if (inet_pton(AF_INET, device_ip, &addr.sin_addr) != 1) {
        return IPA_ERR_INVALID_IP;
    }

    if (g_pairing) {
        idevice_pairing_file_free(g_pairing);
        g_pairing = NULL;
    }

    BAIL_IF_STOPPING();
    if ((err = idevice_pairing_file_read(pairing_file, &g_pairing))) {
        idevice_error_free(err);
        return IPA_ERR_PAIRING_READ;
    }

    BAIL_IF_STOPPING();
    if ((err = idevice_tcp_provider_new((struct sockaddr *)&addr,
                                        g_pairing,
                                        "LocationSimCLI",
                                        &g_provider)))
    {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_PROVIDER_CREATE;
    }
    // idevice_tcp_provider_new takes ownership of g_pairing (Rust moves it).
    // NULL the pointer so cleanup_all() never attempts a second free.
    g_pairing = NULL;

    BAIL_IF_STOPPING();
    if ((err = core_device_proxy_connect(g_provider, &g_core_device))) {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_CORE_DEVICE;
    }
    idevice_provider_free(g_provider);
    g_provider = NULL;

    BAIL_IF_STOPPING();
    uint16_t rsd_port;
    if ((err = core_device_proxy_get_server_rsd_port(g_core_device,
                                                     &rsd_port)))
    {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_RSD_PORT;
    }

    BAIL_IF_STOPPING();
    if ((err = core_device_proxy_create_tcp_adapter(g_core_device,
                                                    &g_adapter)))
    {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_ADAPTER_CREATE;
    }
    g_core_device = NULL;

    BAIL_IF_STOPPING();
    AdapterStreamHandle *stream = NULL;
    if ((err = adapter_connect(g_adapter, rsd_port, (ReadWriteOpaque **)&stream))) {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_STREAM;
    }

    BAIL_IF_STOPPING();
    if ((err = rsd_handshake_new((ReadWriteOpaque *)stream, &g_handshake))) {
        idevice_error_free(err);
        adapter_stream_close(stream);
        cleanup_all();
        return IPA_ERR_HANDSHAKE;
    }

    BAIL_IF_STOPPING();
    if ((err = remote_server_connect_rsd(g_adapter,
                                         g_handshake,
                                         &g_remote_server)))
    {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_REMOTE_SERVER;
    }
    g_adapter   = NULL;
    g_handshake = NULL;

    BAIL_IF_STOPPING();
    if ((err = location_simulation_new(g_remote_server,
                                       &g_location_sim))) {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_LOCATION_SIM;
    }
    g_remote_server = NULL;

    BAIL_IF_STOPPING();
    if ((err = location_simulation_set(g_location_sim,
                                       latitude,
                                       longitude))) {
        idevice_error_free(err);
        cleanup_all();
        return IPA_ERR_LOCATION_SET;
    }

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
