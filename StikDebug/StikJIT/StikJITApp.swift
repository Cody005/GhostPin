//
//  StikJITApp.swift
//  StikJIT
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI
import Network
import UniformTypeIdentifiers

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
        DispatchQueue.main.async { self.coolisMounted = currentlyMounted }
        guard isPairing(), !currentlyMounted else { return }

        mountingThread?.cancel()
        mountingThread = nil

        let thread = Thread { [weak self] in
            guard let self else { return }
            let err = mountPersonalDDI(
                imagePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path,
                trustcachePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path,
                manifestPath: URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path
            )
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
    let host = NWEndpoint.Host(targetIP)
    let port = NWEndpoint.Port(rawValue: 62078)!
    let connection = NWConnection(host: host, port: port, using: .tcp)
    var timeoutWorkItem: DispatchWorkItem?
    
    timeoutWorkItem = DispatchWorkItem { [weak connection] in
        if connection?.state != .ready {
            connection?.cancel()
            DispatchQueue.main.async {
                if timeoutWorkItem?.isCancelled == false {
                    let message = "[TIMEOUT] Could not reach the device at \(targetIP). Make sure it’s online and on the same network."
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

