//
//  StikJITApp.swift
//  StikJIT
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI
import Network
import UniformTypeIdentifiers

// MARK: - Network Path Monitoring

private let networkPathMonitor = NWPathMonitor()
private var lastNetworkPath: NWPath?

/// Starts monitoring the active network path. Call once at app launch.
func startNetworkPathMonitoring() {
    networkPathMonitor.pathUpdateHandler = { path in
        lastNetworkPath = path
    }
    networkPathMonitor.start(queue: DispatchQueue.global(qos: .utility))
}

/// Returns true if the current active path appears to be using cellular.
/// Falls back to false if the path has not been determined yet.
func isActiveConnectionCellular() -> Bool {
    guard let path = lastNetworkPath else { return false }
    return path.usesInterfaceType(.cellular)
}

/// Human-readable description of the active interface for diagnostics.
func currentNetworkInterfaceDescription() -> String {
    guard let path = lastNetworkPath else { return "unknown" }
    if path.usesInterfaceType(.wifi) { return "WiFi" }
    if path.usesInterfaceType(.cellular) { return "cellular" }
    if path.usesInterfaceType(.wiredEthernet) { return "wired" }
    if path.usesInterfaceType(.loopback) { return "loopback" }
    return "other"
}

// Register default settings before the app starts
private func registerAdvancedOptionsDefault() {
    UserDefaults.standard.register(defaults: ["keepAliveAudio": true])
    UserDefaults.standard.register(defaults: ["keepAliveLocation": true])
    UserDefaults.standard.register(defaults: ["routeStepInterval": 6.0])
    UserDefaults.standard.register(defaults: ["routeLoopEnabled": true])
}

// MARK: - Main App

@main
struct LocationSimulatorApp: App {
    @StateObject private var mount = MountingProgress.shared

    init() {
        registerAdvancedOptionsDefault()
        startNetworkPathMonitoring()
        if let fixMethod  = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:))),
           let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onAppear {
                    Task {
                        let fileManager = FileManager.default
                        for item in ddiDownloadItems {
                            let dest = URL.documentsDirectory.appendingPathComponent(item.relativePath)
                            if fileManager.fileExists(atPath: dest.path) { continue }
                            do {
                                try await downloadDDIFile(from: item.urlString, to: dest)
                            } catch {
                                await MainActor.run {
                                    showAlert(title: "DDI Download Error",
                                              message: error.localizedDescription,
                                              showOk: true)
                                }
                                break
                            }
                        }
                    }
                }
        }
    }
}

// MARK: - DDI Mounting

class MountingProgress: ObservableObject {
    static let shared = MountingProgress()
    @Published var mountProgress: Double = 0.0
    @Published var mountingThread: Thread?
    @Published var coolisMounted: Bool = false

    func checkforMounted() {
        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()
            DispatchQueue.main.async { self.coolisMounted = mounted }
        }
    }

    func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
        guard total > 0 else { return }
        let pct = Double(progress) / Double(total) * 100.0
        DispatchQueue.main.async { self.mountProgress = pct }
    }

    func pubMount() {
        mountIfNeeded()
    }

    private func mountIfNeeded() {
        let currentlyMounted = isMounted()
        print("[GhostPin] mountIfNeeded: isPairing=\(isPairing()) currentlyMounted=\(currentlyMounted)")
        fflush(stdout)
        DispatchQueue.main.async { self.coolisMounted = currentlyMounted }
        guard isPairing(), !currentlyMounted else { return }

        mountingThread?.cancel()
        mountingThread = nil

        let imagePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        let manifestPath = URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path

        let thread = Thread { [weak self] in
            guard let self else { return }
            let err = mountPersonalDDI(
                imagePath: imagePath,
                trustcachePath: trustcachePath,
                manifestPath: manifestPath
            )
            print("[GhostPin] mountIfNeeded: mountPersonalDDI returned error=\(err ?? "nil")")
            fflush(stdout)
            DispatchQueue.main.async {
                if let err {
                    showAlert(title: "DDI Mount Failed", message: err, showOk: true, showTryAgain: true) { retry in
                        if retry { self.mountIfNeeded() }
                    }
                } else {
                    self.coolisMounted = true
                    self.checkforMounted()
                }
                self.mountingThread = nil
            }
        }
        thread.qualityOfService = .background
        thread.name = "mounting"
        thread.start()
        mountingThread = thread
    }
}

// MARK: - DDI Download

private struct DDIDownloadItem {
    let relativePath: String
    let urlString: String
}

private let ddiDownloadItems: [DDIDownloadItem] = [
    .init(relativePath: "DDI/BuildManifest.plist",
          urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"),
    .init(relativePath: "DDI/Image.dmg",
          urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"),
    .init(relativePath: "DDI/Image.dmg.trustcache",
          urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"),
]

private func downloadDDIFile(from urlString: String, to dest: URL) async throws {
    guard let url = URL(string: urlString) else { return }
    let (tmp, _) = try await URLSession.shared.download(from: url)
    let fm = FileManager.default
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try fm.moveItem(at: tmp, to: dest)
}

typealias IdevicePairingFile = OpaquePointer

func isPairing() -> Bool {
    let pairingpath = URL.documentsDirectory.appendingPathComponent("pairingFile.plist").path
    var pairingFile: IdevicePairingFile?
    let err = idevice_pairing_file_read(pairingpath, &pairingFile)
    if err != nil { return false }
    idevice_pairing_file_free(pairingFile)
    return true
}

func checkDeviceConnection(callback: @escaping (Bool, String?) -> Void) {
    let targetIP = DeviceConnectionContext.targetIPAddress

    // LocalDevVPN typically routes to a Mac/peer on the same local network.
    // On cellular the VPN's outer interface is LTE and that peer is unreachable,
    // which produces a TCP RST on 10.7.0.1:49152. Warn immediately so the user
    // isn't left waiting 20s for a timeout that looks like a hung test.
    if isActiveConnectionCellular() {
        DispatchQueue.main.async {
            callback(false, "Cellular data is active. Connect to the same WiFi network as your Mac/development peer and ensure LocalDevVPN is connected.")
        }
        return
    }

    let host = NWEndpoint.Host(targetIP)
    // RemotePairing (RPPairing) port — matches heartbeat.m/location_simulation.c.
    // Port 62078 (lockdownd) is blocked by iOS 26.4+'s VPN-netmask restriction.
    let port = NWEndpoint.Port(rawValue: 49152)!
    let connection = NWConnection(host: host, port: port, using: .tcp)
    var timeoutWorkItem: DispatchWorkItem?

    timeoutWorkItem = DispatchWorkItem { [weak connection] in
        if connection?.state != .ready {
            connection?.cancel()
            DispatchQueue.main.async {
                if timeoutWorkItem?.isCancelled == false {
                    let message = "[TIMEOUT] Could not reach the device at \(targetIP) over \(currentNetworkInterfaceDescription()). Make sure it’s online, on the same network, and LocalDevVPN is connected."
                    callback(false, message)
                }
            }
        }
    }

    connection.stateUpdateHandler = { [weak connection] state in
        switch state {
        case .ready:
            timeoutWorkItem?.cancel()
            connection?.cancel()
            DispatchQueue.main.async {
                callback(true, nil)
            }
        case .failed(let error):
            timeoutWorkItem?.cancel()
            connection?.cancel()
            DispatchQueue.main.async {
                let message = "Could not reach the device at \(targetIP): \(error.localizedDescription)"
                callback(false, message)
            }
        case .waiting(let error):
            // Log routing/permission-type problems for diagnostics instead of
            // silently waiting for the generic timeout.
            print("[GhostPin] checkDeviceConnection: waiting on \(targetIP):49152 over \(currentNetworkInterfaceDescription()) - \(error)")
            fflush(stdout)
        default:
            break
        }
    }

    connection.start(queue: .global())
    if let workItem = timeoutWorkItem {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: workItem)
    }
}

public func showAlert(title: String, message: String, showOk: Bool, showTryAgain: Bool = false, primaryButtonText: String? = nil, completion: ((Bool) -> Void)? = nil) {
    DispatchQueue.main.async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = scene.windows.first?.rootViewController else {
            return
        }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        if showTryAgain {
            alert.addAction(UIAlertAction(title: primaryButtonText ?? "Try Again", style: .default) { _ in
                completion?(true)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completion?(false)
            })
        } else if showOk {
            alert.addAction(UIAlertAction(title: primaryButtonText ?? "OK", style: .default) { _ in
                completion?(true)
            })
        } else {
             alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completion?(true)
            })
        }
        
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        topController.present(alert, animated: true)
    }
}

