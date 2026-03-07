//
//  location_simulation.h
//  StikDebug
//
//  Created by Stephen on 8/3/25.
//

#ifndef LOCATION_SIMULATION_H
#define LOCATION_SIMULATION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Success / error codes
#define IPA_OK                     0
#define IPA_ERR_INVALID_IP         1
#define IPA_ERR_PAIRING_READ       2
#define IPA_ERR_PROVIDER_CREATE    3
#define IPA_ERR_CORE_DEVICE        4
#define IPA_ERR_RSD_PORT           5
#define IPA_ERR_ADAPTER_CREATE     6
#define IPA_ERR_STREAM             7
#define IPA_ERR_HANDSHAKE          8
#define IPA_ERR_REMOTE_SERVER      9
#define IPA_ERR_LOCATION_SIM      10
#define IPA_ERR_LOCATION_SET      11
#define IPA_ERR_LOCATION_CLEAR    12
#define IPA_ERR_CANCELLED         13

/**
 * Simulate the device’s location.
 * @param device_ip     IP address of the device.
 * @param latitude      Latitude to simulate.
 * @param longitude     Longitude to simulate.
 * @param pairing_file  Path to the pairing file.
 * @return IPA_OK (0) on success, or one of the IPA_ERR_* codes.
 */
int simulate_location(const char *device_ip,
                      double latitude,
                      double longitude,
                      const char *pairing_file);

/**
 * Prepare for a new simulation session. Resets the stop flag.
 * Must be dispatched onto the serial locationQueue before simulate_location.
 */
void start_simulation(void);

/**
 * Cancel any in-flight simulate_location call immediately.
 * Only sets the atomic stop flag — safe to call from any thread.
 */
void cancel_simulation(void);

/**
 * Clear any simulated location.
 * @return IPA_OK (0) on success, or IPA_ERR_LOCATION_CLEAR.
 */
int clear_simulated_location(void);

#ifdef __cplusplus
}
#endif

#endif /* LOCATION_SIMULATION_H */
