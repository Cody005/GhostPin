import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SimulationSettingsView: View {
    @AppStorage("customTargetIP") private var customTargetIP = ""
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("routeStepInterval") private var routeStepInterval = 6.0
    @AppStorage("routeLoopEnabled") private var routeLoopEnabled = true

    @State private var showPairingImporter = false
    @State private var pairingStatusMessage: String?
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusIsError = false
    @State private var isTestingConnection = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private var pairingURL: URL {
        URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingURL.path)
    }

    private var resolvedIP: String {
        let trimmed = customTargetIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "10.7.0.1" : trimmed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                pairingCard
                connectionCard
                routeCard
                keepAliveCard
                helpCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.08, blue: 0.14), Color(red: 0.03, green: 0.16, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Simulation Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
                UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
                .propertyList
            ],
            allowsMultipleSelection: false,
            onCompletion: handlePairingImport
        )
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location Simulator")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text("Set pins, run routes, and keep simulation active in the background.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.41, blue: 0.36), Color(red: 0.1, green: 0.24, blue: 0.39)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var pairingCard: some View {
        SettingCard(title: "Pairing File", subtitle: "Required for CoreDevice connection") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: pairingExists ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(pairingExists ? Color.green : Color.red)
                    Text(pairingExists ? "Pairing file available" : "No pairing file imported")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Button {
                    showPairingImporter = true
                } label: {
                    Label("Import Pairing File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if let pairingStatusMessage {
                    Text(pairingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    private var connectionCard: some View {
        SettingCard(title: "Connection", subtitle: "Target IP and quick reachability check") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Target IP")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    TextField("10.7.0.1", text: $customTargetIP)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    testConnection()
                } label: {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        Text(isTestingConnection ? "Testing..." : "Test Connection")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isTestingConnection)

                if let connectionStatusMessage {
                    Text(connectionStatusMessage)
                        .font(.caption)
                        .foregroundStyle(connectionStatusIsError ? Color.red : Color.green)
                }
            }
        }
    }

    private var routeCard: some View {
        SettingCard(title: "Route Simulation", subtitle: "Timing and loop preferences") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Step Interval")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text("\(Int(routeStepInterval))s")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white)
                }
                Slider(value: $routeStepInterval, in: 2...30, step: 1)
                    .tint(Color(red: 0.31, green: 0.9, blue: 0.75))

                Toggle("Loop route after final stop", isOn: $routeLoopEnabled)
                    .tint(Color(red: 0.31, green: 0.9, blue: 0.75))
                    .foregroundStyle(.white)
            }
        }
    }

    private var keepAliveCard: some View {
        SettingCard(title: "Background Keep-Alive", subtitle: "Improve simulation persistence while app is backgrounded") {
            VStack(spacing: 10) {
                Toggle("Silent Audio Keep-Alive", isOn: $keepAliveAudio)
                    .tint(Color(red: 0.31, green: 0.9, blue: 0.75))
                    .foregroundStyle(.white)
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled {
                            BackgroundAudioManager.shared.start()
                        } else {
                            BackgroundAudioManager.shared.stop()
                        }
                    }

                Toggle("Background Location Keep-Alive", isOn: $keepAliveLocation)
                    .tint(Color(red: 0.31, green: 0.9, blue: 0.75))
                    .foregroundStyle(.white)
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled {
                            BackgroundLocationManager.shared.stop()
                        }
                    }
            }
        }
    }

    private var helpCard: some View {
        SettingCard(title: "Help", subtitle: "Guides and support") {
            VStack(spacing: 8) {
                Link(destination: URL(string: "https://github.com/StephenDev0/StikDebug-Guide/blob/main/pairing_file.md")!) {
                    Label("Pairing File Guide", systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Link(destination: URL(string: "https://discord.gg/qahjXNTDwS")!) {
                    Label("Community Support", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(.white)
            .font(.footnote)
        }
    }

    private func handlePairingImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertTitle = "Import Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if access {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                if FileManager.default.fileExists(atPath: pairingURL.path) {
                    try FileManager.default.removeItem(at: pairingURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: pairingURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURL.path)
                pairingStatusMessage = "Pairing file imported and secured."
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
            } catch {
                alertTitle = "Import Failed"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatusMessage = nil
        checkDeviceConnection(callback: { isReachable, message in
            isTestingConnection = false
            connectionStatusIsError = !isReachable
            if isReachable {
                connectionStatusMessage = "Device reachable at \(resolvedIP):62078"
            } else {
                connectionStatusMessage = message ?? "Connection test failed."
            }
        })
    }
}

private struct SettingCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        SimulationSettingsView()
    }
}
