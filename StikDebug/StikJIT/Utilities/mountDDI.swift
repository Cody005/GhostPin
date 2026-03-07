import Foundation

enum MountCheckResult {
    case mounted
    case notMounted
    case unreachable
}

func checkMountStatus() -> MountCheckResult {
    do {
        let result = try JITEnableContext.shared.getMountedDeviceCount()
        return result > 0 ? .mounted : .notMounted
    } catch {
        return .unreachable
    }
}

func isMounted() -> Bool {
    return checkMountStatus() == .mounted
}

func mountPersonalDDI(imagePath: String,
                      trustcachePath: String,
                      manifestPath: String) -> String? {
    do {
        try JITEnableContext.shared.mountPersonalDDI(withImagePath: imagePath,
                                                     trustcachePath: trustcachePath,
                                                     manifestPath: manifestPath)
        return nil
    } catch {
        return error.localizedDescription
    }
}
