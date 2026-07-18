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
    private var debounceWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        debounceWorkItem?.cancel()
        if query.isEmpty {
            results = []
            completer.queryFragment = ""
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.completer.queryFragment = query
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
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
    @State private var isSearchActive = false
    @FocusState private var searchFieldIsFocused: Bool
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

    // Redesigned frontend state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var mapScope
    @State private var selectedPlaceName: String?
    @State private var selectedPlaceSubtitle: String?
    @State private var mapStyleChoice: MapStyleChoice = .standardCinematic
    @State private var is3DActive = false
    @State private var currentCamera: MapCamera?
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var lookAroundTask: Task<Void, Never>?
    @State private var isLookAroundDismissed = false
    @State private var geocoder = CLGeocoder()

    /// Optional real weather values provided by the app. The capsule stays
    /// hidden when no value exists — no weather service is added here.
    var weatherSymbolName: String?
    var weatherTemperatureText: String?

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

    private var currentMapStyle: MapStyle {
        switch mapStyleChoice {
        case .standardCinematic:
            return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .all, showsTraffic: false)
        case .hybridSatellite:
            return .hybrid(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $position, scope: mapScope) {
                UserAnnotation()
                if let coordinate {
                    Annotation("", coordinate: coordinate, anchor: .bottom) {
                        EquatableView(content: CustomPinView(isActive: isSimulationActive))
                            .scaleEffect(pinDropped ? 1 : 0.3)
                            .opacity(pinDropped ? 1 : 0)
                            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: pinDropped)
                            .accessibilityLabel(selectedPlaceName ?? "Selected location")
                    }
                }
            }
            .mapStyle(currentMapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                currentCamera = context.camera
                is3DActive = context.camera.pitch > 5
            }
            .onTapGesture { point in
                collapseSearch()
                if let loc = proxy.convert(point, from: .local) {
                    handleMapTap(at: loc)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: coordinate) { _, new in
            guard shouldCenterOnCoordinate, let new else { return }
            shouldCenterOnCoordinate = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                position = .camera(MapCamera(centerCoordinate: new, distance: 1600, heading: 0, pitch: 35))
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if isSearchActive && !searchText.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if searchCompleter.results.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("No Results")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                } else {
                    let results = Array(searchCompleter.results.prefix(6))
                    ForEach(results, id: \.self) { result in
                        Button {
                            selectSearchResult(result)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if result != results.last {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .simGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxHeight: 320)
        }
    }

    private var mapControlStack: some View {
        VStack(spacing: 12) {
            MapControlButton(
                symbol: mapStyleChoice == .hybridSatellite ? "globe.americas.fill" : "map",
                label: "Map style",
                hint: "Switches between the standard map and satellite imagery",
                isSelected: mapStyleChoice == .hybridSatellite
            ) {
                mapStyleChoice = mapStyleChoice == .standardCinematic ? .hybridSatellite : .standardCinematic
            }

            MapControlButton(
                symbol: "view.3d",
                label: "3D map",
                hint: "Toggles the tilted three-dimensional camera",
                isSelected: is3DActive
            ) {
                toggle3D()
            }

            MapControlButton(
                symbol: "location",
                label: "Current location",
                hint: "Centers the map on your current location"
            ) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                    position = .userLocation(fallback: .automatic)
                }
            }

            MapCompass(scope: mapScope)
        }
    }

    @ViewBuilder
    private var lookAroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lookAroundScene != nil && !isLookAroundDismissed && !isSearchActive {
                lookAroundCard
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
            }
            if lookAroundScene != nil && !isSearchActive {
                MapControlButton(
                    symbol: "binoculars.fill",
                    label: "Look Around",
                    hint: "Shows a street-level preview of the selected location",
                    isSelected: !isLookAroundDismissed
                ) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        isLookAroundDismissed.toggle()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lookAroundCard: some View {
        LookAroundPreview(scene: $lookAroundScene)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 230)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        isLookAroundDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("Close Look Around preview")
            }
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            .accessibilityLabel("Look Around preview. Tap to expand.")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search for a place", text: $searchText)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFieldIsFocused)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.update(query: newValue)
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCompleter.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            } else if isSearchActive {
                Button("Cancel") {
                    collapseSearch()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .simGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
        .onTapGesture {
            guard !isSearchActive else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isSearchActive = true
            }
            searchFieldIsFocused = true
        }
    }

    private var selectedTitleText: String {
        if let selectedPlaceName { return selectedPlaceName }
        if let coordinate { return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude) }
        return ""
    }

    private var selectedSubtitleText: String {
        if let selectedPlaceSubtitle { return selectedPlaceSubtitle }
        if let coordinate { return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude) }
        return ""
    }

    private var actionCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTitleText)
                        .font(.headline)
                        .lineLimit(1)
                    Text(selectedSubtitleText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        isSearchActive = true
                    }
                    searchFieldIsFocused = true
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Searches for a different place")

                if isSimulationActive {
                    SimulationStatusBadge()
                } else {
                    Button {
                        clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selected location")
                }
            }

            primaryActionButton

            if !pairingExists {
                Label("Import a pairing file in Settings to enable simulation", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .simGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if isSimulationActive {
            let stopButton = Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                stopSimulation()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            if #available(iOS 26.0, *) {
                stopButton
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            } else {
                stopButton
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        } else {
            let simulateButton = Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                simulatePin()
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting…")
                            .font(.headline)
                    } else {
                        Label("Simulate", systemImage: "play.fill")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .disabled(!pairingExists || isBusy || coordinate == nil)
            if #available(iOS 26.0, *) {
                simulateButton
                    .buttonStyle(.glassProminent)
                    .tint(Color.accentColor)
            } else {
                simulateButton
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            lookAroundControls

            if isSearchActive {
                suggestionList
            }

            if coordinate != nil && !isSearchActive {
                actionCard
            } else {
                searchBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: isSearchActive)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: coordinate == nil)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: isSimulationActive)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: lookAroundScene == nil)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: isLookAroundDismissed)
    }

    // MARK: - Body

    var body: some View {
        mapLayer
            .overlay(alignment: .topLeading) {
                WeatherCapsuleView(symbolName: weatherSymbolName, temperatureText: weatherTemperatureText)
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                mapControlStack
                    .padding(.trailing, 12)
                    .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel
            }
            .mapScope(mapScope)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onChange(of: isSimulationActive) { _, active in
                if active {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            .onChange(of: searchFieldIsFocused) { _, focused in
                if focused && !isSearchActive {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        isSearchActive = true
                    }
                }
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
                lookAroundTask?.cancel()
                geocoder.cancelGeocode()
            }
    }

    // MARK: - Frontend Interactions

    private func collapseSearch() {
        searchFieldIsFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isSearchActive = false
        }
    }

    private func handleMapTap(at loc: CLLocationCoordinate2D) {
        let isFirstPin = coordinate == nil
        if isFirstPin { pinDropped = false }
        coordinate = loc
        if isFirstPin { withAnimation { pinDropped = true } }
        UISelectionFeedbackGenerator().selectionChanged()
        updatePlaceDetails(for: loc)
        if isSimulationActive {
            pushLiveLocationUpdate(loc)
        }
    }

    private func clearSelection() {
        guard !isSimulationActive else { return }
        coordinate = nil
        pinDropped = false
        selectedPlaceName = nil
        selectedPlaceSubtitle = nil
        lookAroundTask?.cancel()
        lookAroundScene = nil
        isLookAroundDismissed = false
        geocoder.cancelGeocode()
    }

    /// Stops the simulation via the existing `clear()` flow but keeps the
    /// selected location and place details visible in the ready state.
    private func stopSimulation() {
        let keptCoordinate = coordinate
        let keptName = selectedPlaceName
        let keptSubtitle = selectedPlaceSubtitle
        clear()
        coordinate = keptCoordinate
        selectedPlaceName = keptName
        selectedPlaceSubtitle = keptSubtitle
        if keptCoordinate != nil { pinDropped = true }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func updatePlaceDetails(for coord: CLLocationCoordinate2D) {
        selectedPlaceName = nil
        selectedPlaceSubtitle = nil
        reverseGeocode(coord)
        requestLookAroundScene(for: coord)
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            guard let placemark = placemarks?.first, coordinate == coord else { return }
            selectedPlaceName = placemark.name ?? placemark.thoroughfare ?? placemark.locality
            let parts = [placemark.locality, placemark.administrativeArea, placemark.country].compactMap { $0 }
            selectedPlaceSubtitle = parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    private func requestLookAroundScene(for coord: CLLocationCoordinate2D) {
        lookAroundTask?.cancel()
        lookAroundScene = nil
        isLookAroundDismissed = false
        lookAroundTask = Task { @MainActor in
            let scene = try? await MKLookAroundSceneRequest(coordinate: coord).scene
            guard !Task.isCancelled else { return }
            lookAroundScene = scene
        }
    }

    /// While simulation is active, pushes the new coordinate to the device
    /// using the existing `simulate_location` fast path (the same call the
    /// resend loop uses) — no full start workflow, no confirmation.
    private func pushLiveLocationUpdate(_ coord: CLLocationCoordinate2D) {
        let ip = deviceIP
        let path = pairingFilePath
        Self.locationQueue.async {
            _ = simulate_location(ip, coord.latitude, coord.longitude, path)
        }
    }

    private func toggle3D() {
        guard let camera = currentCamera else { return }
        is3DActive.toggle()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            position = .camera(
                MapCamera(
                    centerCoordinate: camera.centerCoordinate,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: is3DActive ? 60 : 0
                )
            )
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
        collapseSearch()
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                pinDropped = false
                shouldCenterOnCoordinate = true
                coordinate = item.placemark.coordinate
                selectedPlaceName = item.name ?? result.title
                selectedPlaceSubtitle = result.subtitle.isEmpty ? nil : result.subtitle
                withAnimation { pinDropped = true }
                UISelectionFeedbackGenerator().selectionChanged()
                requestLookAroundScene(for: item.placemark.coordinate)
                if isSimulationActive {
                    pushLiveLocationUpdate(item.placemark.coordinate)
                }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    static func == (lhs: CustomPinView, rhs: CustomPinView) -> Bool {
        lhs.isActive == rhs.isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Restrained pulsing halo when simulation is live
                if isActive {
                    Circle()
                        .stroke(Color.green.opacity(0.45), lineWidth: 2.5)
                        .frame(width: 46, height: 46)
                        .scaleEffect(pulse ? 1.35 : 0.95)
                        .opacity(pulse ? 0 : 0.9)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                                pulse = true
                            }
                        }
                        .onDisappear { pulse = false }
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

// MARK: - Redesigned UI Components

enum MapStyleChoice {
    case standardCinematic
    case hybridSatellite
}

/// Liquid Glass surface on iOS 26+, with a native material fallback on
/// the project's older supported iOS versions.
extension View {
    @ViewBuilder
    func simGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
    }
}

private struct MapControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Circular floating glass control used for the map-style, 3D, recenter
/// and Look Around buttons.
struct MapControlButton: View {
    let symbol: String
    let label: String
    let hint: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(MapControlPressStyle())
        .simGlass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Compact floating capsule showing real weather values supplied by the
/// app. Hidden entirely when no value exists.
struct WeatherCapsuleView: View {
    let symbolName: String?
    let temperatureText: String?

    var body: some View {
        if let symbolName {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.multicolor)
                if let temperatureText {
                    Text(temperatureText)
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .simGlass(in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current weather\(temperatureText.map { ", \($0)" } ?? "")")
        }
    }
}

/// Small green indicator shown in the action card while simulation is live.
struct SimulationStatusBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.5 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text("Simulating")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.12), in: Capsule())
        .accessibilityLabel("Simulation active")
    }
}
