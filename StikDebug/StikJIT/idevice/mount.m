//
//  mount1.m
//  StikDebug
//
//  Created by s s on 2025/12/6.
//
#include "mount.h"
#import "JITEnableContext.h"
#import "JITEnableContextInternal.h"
#include <stdio.h>
@import Foundation;

#define GP_LOG(fmt, ...) do { fprintf(stderr, "[GhostPin] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

NSError* makeError(int code, NSString* msg) {
    return [NSError errorWithDomain:@"StikMount"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

size_t getMountedDeviceCount(AdapterHandle* adapter, RsdHandshakeHandle* handshake, NSError** error) {
    ImageMounterHandle *client = NULL;
    IdeviceFfiError *err = image_mounter_connect_rsd(adapter, handshake, &client);
    if (err) {
        GP_LOG("getMountedDeviceCount: image_mounter_connect_rsd FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return 0;
    }

    plist_t *devices = NULL;
    size_t deviceLength = 0;
    err = image_mounter_copy_devices(client, &devices, &deviceLength);
    image_mounter_free(client);
    if (err) {
        GP_LOG("getMountedDeviceCount: image_mounter_copy_devices FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return 0;
    }

    for (int i = 0; i < (int)deviceLength; i++) {
        plist_free(devices[i]);
    }
    idevice_data_free((uint8_t *)devices, deviceLength * sizeof(plist_t));
    GP_LOG("getMountedDeviceCount: deviceLength=%zu", deviceLength);
    return deviceLength;
}

int mountPersonalDDI(AdapterHandle* adapter, RsdHandshakeHandle* handshake, NSString* imagePath, NSString* trustcachePath, NSString* manifestPath, NSError** error) {
    NSData *image         = [NSData dataWithContentsOfFile:imagePath];
    NSData *trustcache    = [NSData dataWithContentsOfFile:trustcachePath];
    NSData *buildManifest = [NSData dataWithContentsOfFile:manifestPath];
    if (!image || !trustcache || !buildManifest) {
        *error = makeError(1, @"Failed to read one or more files");
        return 1;
    }

    // Connecting via the RemotePairing-discovered RSD handshake already
    // implies an authenticated session, so no explicit lockdownd_start_session
    // (and therefore no separate pairing file) is required here.
    GP_LOG("mountPersonalDDI: connecting lockdownd via RSD");
    LockdowndClientHandle *lockdownClient = NULL;
    IdeviceFfiError *err = lockdownd_connect_rsd(adapter, handshake, &lockdownClient);
    if (err) {
        GP_LOG("lockdownd_connect_rsd FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(6, @(err->message));
        idevice_error_free(err);
        return 6;
    }

    plist_t uniqueChipIDPlist = NULL;
    err = lockdownd_get_value(lockdownClient, "UniqueChipID", NULL, &uniqueChipIDPlist);
    lockdownd_client_free(lockdownClient);
    if (err) {
        GP_LOG("lockdownd_get_value(UniqueChipID) FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(8, @(err->message));
        idevice_error_free(err);
        return 8;
    }

    uint64_t uniqueChipID = 0;
    plist_get_uint_val(uniqueChipIDPlist, &uniqueChipID);
    plist_free(uniqueChipIDPlist);

    GP_LOG("mountPersonalDDI: UniqueChipID=%llu, connecting image_mounter via RSD", uniqueChipID);
    ImageMounterHandle *mounterClient = NULL;
    err = image_mounter_connect_rsd(adapter, handshake, &mounterClient);
    if (err) {
        GP_LOG("image_mounter_connect_rsd FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(9, @(err->message));
        idevice_error_free(err);
        return 9;
    }

    GP_LOG("mountPersonalDDI: mounting image=%lu bytes trust=%lu bytes manifest=%lu bytes", (unsigned long)[image length], (unsigned long)[trustcache length], (unsigned long)[buildManifest length]);
    err = image_mounter_mount_personalized_rsd(
        mounterClient,
        adapter,
        handshake,
        [image bytes],
        [image length],
        [trustcache bytes],
        [trustcache length],
        [buildManifest bytes],
        [buildManifest length],
        NULL,
        uniqueChipID
    );
    image_mounter_free(mounterClient);

    if (err) {
        GP_LOG("image_mounter_mount_personalized_rsd FAILED: code=%d message=%s", err->code, err->message);
        *error = makeError(10, @(err->message));
        idevice_error_free(err);
        return 10;
    }

    GP_LOG("mountPersonalDDI: mount succeeded");
    return 0;
}

@implementation JITEnableContext(DDI)

- (NSUInteger)getMountedDeviceCount:(NSError**)error {
    [self ensureHeartbeatWithError:error];
    if (*error) { return 0; }
    return getMountedDeviceCount([self getTunnelAdapterHandle], [self getTunnelHandshakeHandle], error);
}

- (NSInteger)mountPersonalDDIWithImagePath:(NSString*)imagePath trustcachePath:(NSString*)trustcachePath manifestPath:(NSString*)manifestPath error:(NSError**)error {
    [self ensureHeartbeatWithError:error];
    if (*error) { return 0; }
    return mountPersonalDDI([self getTunnelAdapterHandle], [self getTunnelHandshakeHandle], imagePath, trustcachePath, manifestPath, error);
}

@end
