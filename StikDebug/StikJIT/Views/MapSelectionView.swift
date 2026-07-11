//
//  MapSelectionView.swift
//  StikJIT
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

struct RouteStopsView: View {
    @Binding var routeStops: [LocationBookmark]
    let bookmarks: [LocationBookmark]

    var body: some View {
        NavigationStack {
            List {
                if routeStops.isEmpty {
                    ContentUnavailableView(
                        "No Route Stops",
                        systemImage: "point.3.filled.connected.trianglepath.dotted",
                        description: Text("Use Add Stop from the simulator screen or copy from bookmarks.")
                    )
                } else {
                    ForEach(routeStops) { stop in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name)
                            Text(String(format: "%.6f, %.6f", stop.latitude, stop.longitude))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onMove { fromOffsets, toOffset in
                        routeStops.move(fromOffsets: fromOffsets, toOffset: toOffset)
                    }
                    .onDelete { offsets in
                        routeStops.remove(atOffsets: offsets)
                    }
                }
            }
            .navigationTitle("Route Stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !bookmarks.isEmpty {
                        Button("Use Bookmarks") {
                            routeStops = bookmarks
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    // Serial queue: simulate_location and clear_simulated_location share C global
    // state — serialising all calls eliminates the use-after-free race.
    // QoS is .utility (not .userInitiated): simulate_location() blocks
    // synchronously on Rust-internal worker threads that run at the OS
    // default QoS, so boosting this queue above that just causes a
    // priority inversion (boosted thread parked on a default-QoS thread)
    // with no actual benefit, since we're blocked either way.
    private static let locationQueue = DispatchQueue(label: "com.stik.location-sim",
                                                    qos: .utility)

    private enum SimulationMode: String, CaseIterable, Identifiable {
        case pin = "Pin"
        case route = "Route"

        var id: String { rawValue }
    }

    @AppStorage("routeStepInterval") private var routeStepInterval = 6.0
    @AppStorage("routeLoopEnabled") private var routeLoopEnabled = true

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pinDropped = false
    @State private var shouldCenterOnCoordinate = false

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    @State private var isBusy = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    // Route simulation
    @State private var simulationMode: SimulationMode = .pin
    @State private var routeStops: [LocationBookmark] = []
    @State private var showRouteManager = false
    @State private var routeTimer: Timer?
    @State private var routeIndex = 0
    @State private var isRouteRunning = false
    @State private var pairingExists = false
    @State private var operationID = UUID()
    @State private var isSimulationActive = false

    // Auto-retry state for the LocalDevVPN Airplane Mode workaround.
    @State private var pendingRetryCoordinate: CLLocationCoordinate2D?
    @State private var pendingRetryIsRoute = false
    @State private var pendingRetryAttempts = 0
    private let maxAutoRetryAttempts = 3

    private var pairingFilePath: String {
        URL.documentsDirectory.appendingPathComponent("pairingFile.plist").path
    }

    private func refreshPairingStatus() {
        pairingExists = FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        let stored = UserDefaults.standard.string(forKey: "customTargetIP") ?? ""
        return stored.isEmpty ? "10.7.0.1" : stored
    }

    private var routeStatusText: String {
        guard !routeStops.isEmpty else { return "No route stops yet" }
        if isRouteRunning {
            return "Running stop \(routeIndex + 1) of \(routeStops.count)"
        }
        return "\(routeStops.count) stops ready"
    }

    // MARK: - Extracted Subviews

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let coordinate {
                    Annotation("", coordinate: coordinate, anchor: .bottom) {
                        EquatableView(content: CustomPinView(isActive: isSimulationActive))
                            .scaleEffect(pinDropped ? 1 : 0.3)
                            .opacity(pinDropped ? 1 : 0)
                            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pinDropped)
                    }
                }
            }
            .environment(\.colorScheme, .dark)
            .mapStyle(.standard(elevation: .flat))
            .onTapGesture { point in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                if let loc = proxy.convert(point, from: .local) {
                    if coordinate == nil {
                        pinDropped = false
                        coordinate = loc
                        withAnimation { pinDropped = true }
                    } else {
                        coordinate = loc
                    }
                }
            }
            .mapControls {
                MapCompass()
            }
        }
        .ignoresSafeArea()
        .onChange(of: coordinate) { _, new in
            guard shouldCenterOnCoordinate, let new else { return }
            shouldCenterOnCoordinate = false
            withAnimation(.easeInOut(duration: 0.4)) {
                position = .region(MKCoordinateRegion(center: new, latitudinalMeters: 1000, longitudinalMeters: 1000))
            }
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if !searchCompleter.results.isEmpty {
            if #available(iOS 26, *) {
                searchList
                    .glassEffect(in: .rect(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            } else {
                searchList
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }

    private var searchList: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
    }

    private func modeChip(_ mode: SimulationMode) -> some View {
        let isActive = simulationMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                simulationMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode == .pin ? "mappin.and.ellipse" : "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                Text(mode.rawValue)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isActive
                            ? LinearGradient(
                                colors: [Color(red: 0.19, green: 0.63, blue: 0.94), Color(red: 0.22, green: 0.86, blue: 0.66)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search location...", text: $searchText)
                .autocorrectionDisabled()
                .foregroundStyle(.primary)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.update(query: newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCompleter.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var floatingMapControls: some View {
        VStack(spacing: 12) {
            Button {
                if let coord = coordinate {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000))
                    }
                }
            } label: {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(coordinate == nil)
            .opacity(coordinate == nil ? 0.45 : 1)

            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    position = .userLocation(fallback: .automatic)
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                modeChip(.pin)
                modeChip(.route)
            }
            .padding(4)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !pairingExists {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Pairing file required")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }

            if let coord = coordinate {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected Pin")
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSimulationActive {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green, in: Capsule())
                    }
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                    Text("Tap the map to drop a pin")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if simulationMode == .pin {
                pinControls
            } else {
                routeControls
            }
        }
        .padding(18)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 24, x: 0, y: 12)
        .padding(.bottom, 24)
        .padding(.horizontal, 16)
    }

    private var pinControls: some View {
        HStack(spacing: 12) {
            Button(action: clear) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.92, green: 0.28, blue: 0.30), Color(red: 0.75, green: 0.18, blue: 0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .red.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!isSimulationActive)
            .opacity(isSimulationActive ? 1 : 0.45)

            Button(action: simulatePin) {
                Label("Simulate", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.19, green: 0.63, blue: 0.94), Color(red: 0.22, green: 0.86, blue: 0.66)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: Color(red: 0.19, green: 0.63, blue: 0.94).opacity(0.35), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!pairingExists || isBusy || coordinate == nil || isSimulationActive)
            .opacity((!pairingExists || isBusy || coordinate == nil || isSimulationActive) ? 0.45 : 1)

            Button {
                showSaveBookmark = true
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .foregroundStyle(.blue)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(coordinate == nil)
            .opacity(coordinate == nil ? 0.45 : 1)
        }
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !routeStops.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    Text(routeStatusText)
                        .lineLimit(1)
                    Spacer()
                    if isSimulationActive {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green, in: Capsule())
                    }
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                    Text("Tap the map to add route stops")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    if isRouteRunning {
                        stopRouteStepping(keepSimulationAlive: true)
                    } else {
                        startRoute()
                    }
                } label: {
                    Label(isRouteRunning ? "Pause" : "Start", systemImage: isRouteRunning ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.19, green: 0.63, blue: 0.94), Color(red: 0.22, green: 0.86, blue: 0.66)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: Color(red: 0.19, green: 0.63, blue: 0.94).opacity(0.35), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!pairingExists || routeStops.isEmpty || isBusy)
                .opacity((!pairingExists || routeStops.isEmpty || isBusy) ? 0.45 : 1)

                Button(action: clear) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.92, green: 0.28, blue: 0.30), Color(red: 0.75, green: 0.18, blue: 0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: .red.opacity(0.25), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!isRouteRunning)
                .opacity(isRouteRunning ? 1 : 0.45)
            }

            HStack(spacing: 12) {
                Button {
                    addCurrentCoordinateToRoute()
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .foregroundStyle(.primary)
                .disabled(coordinate == nil)
                .opacity(coordinate == nil ? 0.45 : 1)

                Button {
                    showRouteManager = true
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            VStack(spacing: 12) {
                searchBar
                searchResultsList
                Spacer()
                controlPanel
            }
        }
        .overlay(alignment: .topTrailing) {
            floatingMapControls
                .padding(.top, 70)
                .padding(.trailing, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showBookmarks = true
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark.fill")
                    }
                    Button {
                        showRouteManager = true
                    } label: {
                        Label("Route Stops", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Save Bookmark", isPresented: $showSaveBookmark) {
            TextField("Name", text: $newBookmarkName)
            Button("Save") { addBookmark() }
            Button("Cancel", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Enter a name for this location.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                pinDropped = false
                shouldCenterOnCoordinate = true
                coordinate = bookmark.coordinate
                withAnimation { pinDropped = true }
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteManager) {
            RouteStopsView(routeStops: $routeStops, bookmarks: bookmarks)
        }
        .onAppear {
            refreshPairingStatus()
            loadBookmarks()
            loadRouteStops()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pairingFileImported)) { _ in
            refreshPairingStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshPairingStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .networkPathChanged)) { _ in
            handleNetworkPathChanged()
        }
        .onChange(of: routeStops) { _, _ in
            saveRouteStops()
        }
        .onDisappear {
            stopResendLoop()
            stopRouteStepping(keepSimulationAlive: false)
            BackgroundAudioManager.shared.stop()
            BackgroundLocationManager.shared.requestStop()
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func loadRouteStops() {
        guard let data = UserDefaults.standard.data(forKey: "routeStops"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else {
            return
        }
        routeStops = decoded
    }

    private func saveRouteStops() {
        if let data = try? JSONEncoder().encode(routeStops) {
            UserDefaults.standard.set(data, forKey: "routeStops")
        }
    }

    private func addCurrentCoordinateToRoute() {
        guard let coord = coordinate else { return }
        let stop = LocationBookmark(
            name: "Stop \(routeStops.count + 1)",
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        routeStops.append(stop)
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                pinDropped = false
                shouldCenterOnCoordinate = true
                coordinate = item.placemark.coordinate
                withAnimation { pinDropped = true }
            }
        }
    }

    private func simulatePin() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        isBusy = true
        operationID = UUID()
        let flowOp = operationID
        ensureSimulationReady { [self] ready in
            guard operationID == flowOp else { return }
            let coord = coord
            guard ready else {
                isBusy = false
                if isActiveConnectionCellular() {
                    pendingRetryCoordinate = coord
                    pendingRetryIsRoute = false
                    pendingRetryAttempts += 1
                    alertTitle = "LocalDevVPN on Cellular"
                    alertMessage = "Device support check failed over cellular. Quick fix: enable Airplane Mode, wait a second, then turn cellular back on. The app will retry automatically when the network changes (attempt \(pendingRetryAttempts)/\(maxAutoRetryAttempts))."
                    showAlert = true
                }
                return
            }
            stopRouteStepping(keepSimulationAlive: false)
            pendingRetryCoordinate = nil
            pendingRetryAttempts = 0
            let currentOp = UUID()
            operationID = currentOp
            submitSimulation(for: coord) { code in
                guard operationID == currentOp else { return }
                isBusy = false
                if code == 0 {
                    isSimulationActive = true
                    showAlert = false
                    beginBackgroundTask()
                    startResendLoop()
                    if UserDefaults.standard.bool(forKey: "keepAliveAudio") {
                        BackgroundAudioManager.shared.start()
                    }
                    BackgroundLocationManager.shared.requestStart()
                } else {
                    handleSimulationFailure(code: code, coord: coord, isRoute: false)
                }
            }
        }
    }

    private func startRoute() {
        guard pairingExists, !isBusy else { return }
        guard !routeStops.isEmpty else {
            alertTitle = "Route Empty"
            alertMessage = "Add at least one stop before starting a route."
            showAlert = true
            return
        }
        isBusy = true
        operationID = UUID()
        let flowOp = operationID
        ensureSimulationReady { [self] ready in
            guard operationID == flowOp else { return }
            let firstStop = routeStops[routeIndex]
            guard ready else {
                isBusy = false
                if isActiveConnectionCellular() {
                    pendingRetryCoordinate = firstStop.coordinate
                    pendingRetryIsRoute = true
                    pendingRetryAttempts += 1
                    alertTitle = "LocalDevVPN on Cellular"
                    alertMessage = "Device support check failed over cellular. Quick fix: enable Airplane Mode, wait a second, then turn cellular back on. The app will retry automatically when the network changes (attempt \(pendingRetryAttempts)/\(maxAutoRetryAttempts))."
                    showAlert = true
                }
                return
            }

            stopResendLoop()
            pendingRetryCoordinate = nil
            pendingRetryAttempts = 0

            if routeIndex >= routeStops.count {
                routeIndex = 0
            }

            coordinate = firstStop.coordinate
            let currentOp = UUID()
            operationID = currentOp

            submitSimulation(for: firstStop.coordinate) { code in
                guard operationID == currentOp else { return }
                isBusy = false
                if code == 0 {
                    isSimulationActive = true
                    showAlert = false
                    beginBackgroundTask()
                    if UserDefaults.standard.bool(forKey: "keepAliveAudio") {
                        BackgroundAudioManager.shared.start()
                    }
                    BackgroundLocationManager.shared.requestStart()
                    isRouteRunning = true
                    scheduleRouteTimer()
                } else {
                    handleSimulationFailure(code: code, coord: firstStop.coordinate, isRoute: true)
                }
            }
        }
    }

    private func scheduleRouteTimer() {
        routeTimer?.invalidate()
        let interval = max(routeStepInterval, 2)
        routeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            advanceRoute()
        }
    }

    private func advanceRoute() {
        guard isRouteRunning, !routeStops.isEmpty else { return }

        var nextIndex = routeIndex + 1
        if nextIndex >= routeStops.count {
            if routeLoopEnabled {
                nextIndex = 0
            } else {
                stopRouteStepping(keepSimulationAlive: true)
                alertTitle = "Route Complete"
                alertMessage = "Reached the final route stop."
                showAlert = true
                return
            }
        }

        routeIndex = nextIndex
        let nextStop = routeStops[nextIndex]
        coordinate = nextStop.coordinate

        let currentOp = operationID
        submitSimulation(for: nextStop.coordinate) { code in
            guard operationID == currentOp else { return }
            if code == 0 {
                showAlert = false
            } else {
                stopRouteStepping(keepSimulationAlive: true)
                alertTitle = "Route Step Failed"
                alertMessage = "Failed at stop \(nextIndex + 1) (error \(code))."
                showAlert = true
            }
        }
    }

    private func stopRouteStepping(keepSimulationAlive: Bool) {
        routeTimer?.invalidate()
        routeTimer = nil
        isRouteRunning = false
        if keepSimulationAlive, coordinate != nil {
            startResendLoop()
        }
    }

    private func handleSimulationFailure(code: Int32, coord: CLLocationCoordinate2D, isRoute: Bool) {
        // IPA_ERR_RPPAIRING_TUNNEL (3) on cellular usually means LocalDevVPN
        // bound to the LTE interface. Stash the coordinate so we can auto-retry
        // when the network path changes (Airplane Mode workaround).
        if code == 3 && isActiveConnectionCellular() {
            pendingRetryCoordinate = coord
            pendingRetryIsRoute = isRoute
            pendingRetryAttempts += 1
            alertTitle = isRoute ? "Route Start Failed" : "Simulation Failed"
            alertMessage = "LocalDevVPN failed to create the tunnel over cellular. Quick fix: enable Airplane Mode, wait a second, then turn cellular back on. The app will retry automatically when the network changes (attempt \(pendingRetryAttempts)/\(maxAutoRetryAttempts))."
            showAlert = true
        } else {
            pendingRetryCoordinate = nil
            pendingRetryAttempts = 0
            alertTitle = isRoute ? "Route Start Failed" : "Simulation Failed"
            alertMessage = "Could not \(isRoute ? "start route" : "simulate location") (error \(code)). Make sure the device is connected and the DDI is mounted."
            showAlert = true
        }
    }

    private func handleNetworkPathChanged() {
        guard pendingRetryCoordinate != nil, !isBusy else { return }
        guard pendingRetryAttempts < maxAutoRetryAttempts else {
            pendingRetryCoordinate = nil
            pendingRetryAttempts = 0
            return
        }

        // A path change happened while we were waiting for the Airplane Mode
        // workaround. Retry the original action so ensureSimulationReady gets
        // another chance to mount/verify the DDI over the now-correct VPN path.
        if pendingRetryIsRoute {
            startRoute()
        } else {
            simulatePin()
        }
    }

    private func submitSimulation(for coord: CLLocationCoordinate2D, completion: @escaping (Int32) -> Void) {
        let ip = deviceIP
        let path = pairingFilePath
        let lat = coord.latitude
        let lon = coord.longitude
        Self.locationQueue.async {
            start_simulation()  // resets g_stopping on the queue thread — no race
            let code = simulate_location(ip, lat, lon, path)
            DispatchQueue.main.async {
                completion(code)
            }
        }
    }

    private func ensureSimulationReady(completion: @escaping (Bool) -> Void) {
        let targetIP = deviceIP
        guard !targetIP.isEmpty else {
            alertTitle = "Missing Target IP"
            alertMessage = "Set a target IP in Settings before simulating."
            showAlert = true
            completion(false)
            return
        }

        guard FileManager.default.fileExists(atPath: pairingFilePath), isPairing() else {
            pairingExists = false
            alertTitle = "Invalid Pairing File"
            alertMessage = "Import a valid pairingFile.plist in Settings, then try again."
            showAlert = true
            completion(false)
            return
        }

        // Run the DDI mount check off the main thread. isMounted() can block
        // for several seconds while startHeartbeat creates the RemotePairing
        // tunnel, and doing that on the main thread causes priority inversion
        // warnings (user-interactive thread waiting on background Rust worker).
        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()
            DispatchQueue.main.async {
                if mounted {
                    completion(true)
                } else {
                    MountingProgress.shared.pubMount()
                    self.alertTitle = "Preparing Device Support"
                    self.alertMessage = "Developer Disk Image is not mounted yet. Please wait a few seconds and try Simulate again."
                    self.showAlert = true
                    completion(false)
                }
            }
        }
    }

    private func clear() {

        // Invalidate any in-flight operations so their callbacks become no-ops
        operationID = UUID()

        // Stop all timers immediately
        stopResendLoop()
        stopRouteStepping(keepSimulationAlive: false)

        // Reset UI state right away — don't wait for the C call
        isBusy = false
        isSimulationActive = false
        coordinate = nil
        endBackgroundTask()
        BackgroundAudioManager.shared.stop()
        BackgroundLocationManager.shared.requestStop()

        // Set the stop flag from the main thread (atomic store — no handle access,
        // so no race). The in-flight simulate_location on the serial queue will see
        // the flag at its next BAIL_IF_STOPPING() check and clean up itself.
        // clear_simulated_location() is then queued to run after it finishes.
        cancel_simulation()
        Self.locationQueue.async {
            _ = clear_simulated_location()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [self] in
            stopResendLoop()
            stopRouteStepping(keepSimulationAlive: false)
            BackgroundAudioManager.shared.stop()
            BackgroundLocationManager.shared.requestStop()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop() {
        guard !isRouteRunning else { return }
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            guard let coord = coordinate, isSimulationActive else { return }
            let ip = deviceIP
            let path = pairingFilePath
            let lat = coord.latitude
            let lon = coord.longitude
            Self.locationQueue.async {
                _ = simulate_location(ip, lat, lon, path)
            }
        }
    }

    private func stopResendLoop() {
        resendTimer?.invalidate()
        resendTimer = nil
    }
}

// MARK: - Custom Pin

struct CustomPinView: View, Equatable {
    var isActive: Bool

    static func == (lhs: CustomPinView, rhs: CustomPinView) -> Bool {
        lhs.isActive == rhs.isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Glow ring when simulation is live
                if isActive {
                    Circle()
                        .stroke(Color.green.opacity(0.5), lineWidth: 3)
                        .frame(width: 48, height: 48)
                }

                // Outer pin body
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isActive
                                ? [Color(red: 0.18, green: 0.82, blue: 0.58), Color(red: 0.12, green: 0.62, blue: 0.90)]
                                : [Color(red: 0.93, green: 0.30, blue: 0.32), Color(red: 0.82, green: 0.18, blue: 0.40)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)

                // Inner icon
                Image(systemName: isActive ? "location.fill" : "mappin")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }

            // Pin tail
            Triangle()
                .fill(
                    LinearGradient(
                        colors: isActive
                            ? [Color(red: 0.12, green: 0.62, blue: 0.90), Color(red: 0.12, green: 0.62, blue: 0.90).opacity(0.5)]
                            : [Color(red: 0.82, green: 0.18, blue: 0.40), Color(red: 0.82, green: 0.18, blue: 0.40).opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 14, height: 10)
                .offset(y: -2)

            // Ground shadow dot
            Ellipse()
                .fill(Color.black.opacity(0.18))
                .frame(width: 18, height: 6)
                .offset(y: 2)
        }
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 4)
    }
}

// Pin tail shape
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark.slash",
                        description: Text("Drop a pin on the map and tap the bookmark icon to save a location.")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
