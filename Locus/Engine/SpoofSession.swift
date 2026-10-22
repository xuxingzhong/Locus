import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case restoring
    case waitingForRealLocation
    case restored
    case restoreUnconfirmed
    case restoreFailed(String)
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .restoring: return "Restoring…"
        case .waitingForRealLocation: return "Waiting for Real Location…"
        case .restored: return "Location Restored"
        case .restoreUnconfirmed: return "Location Not Confirmed"
        case .restoreFailed: return "Restore Failed"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published private(set) var restoreDetail: String?
    @Published var joystickActive = false
    @Published private(set) var isPreparingForUpdate = false
    /// Explicit map-camera request for programmatic selections such as Favorites/Recents.
    @Published var mapFocusRequest: MapFocusRequest?

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: Timer?
    private var simulationGeneration: UInt64 = 0
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()
    private let realLocationStore = RealLocationStore.shared
    private let recoveryMonitor = RecoveryLocationMonitor()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        if case .restoring = status { return true }
        if case .waitingForRealLocation = status { return true }
        if case .restoreFailed = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard !isBusy && status != .restoring && status != .waitingForRealLocation else {
            lastError = "Wait for the current location operation to finish."
            return
        }
        guard LocalDevVPN.isConnected else {
            lastError = "Connect LocalDevVPN before teleporting."
            LocalDevVPN.openOrInstall()
            return
        }
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        simulationGeneration &+= 1
        pin = coordinate
        // A favorite/recent may be tapped repeatedly or may match the current pin.
        // Publish a new identity every time so MapHomeView always receives a camera request.
        mapFocusRequest = MapFocusRequest(coordinate: coordinate)
        apply(coordinate, pairing: pairing, markRecent: true)
    }

    /// Normal recovery first clears the active DVT channel, THEN evaluates
    /// fresh CoreLocation fixes. A second nearby transition is only allowed
    /// for an observed old-fake/likely-real oscillation. Manual backup is
    /// never used automatically; it is an explicit fallback in Settings.
    func stop(pairing: PairingStore, useManualBackup: Bool = false) {
        guard !isBusy && status != .restoring && status != .waitingForRealLocation else { return }

        // Disarm queued writes, route/joystick and all health/resend timers.
        simulationGeneration &+= 1
        let restoreGeneration = simulationGeneration
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()

        let oldSimulated = simulated.map {
            ChinaCoordinateTransform.injectionCoordinate(from: $0)
        }
        let manualBackup = useManualBackup ? realLocationStore.manualBackup?.coordinate : nil
        let allowSmartRescue =
            (UserDefaults.standard.object(forKey: RealLocationStore.smoothRestoreKey) as? Bool ?? true)
            && !useManualBackup

        status = .restoring
        isBusy = true
        restoreDetail = String(localized: "Clearing the simulated location…")
        lastError = nil

        let pairingPath = pairing.pairingPath
        let deviceIP = TunnelConfig.targetIP

        Task {
            // Do not inject the v1.0.7 saved automatic coordinate here: it
            // might be obsolete because the user has physically moved.
            let cleared = await Task.detached(priority: .userInitiated) {
                if let manualBackup {
                    // Explicit manual fallback must also work when the former
                    // DVT channel was already lost or the app was relaunched.
                    return LocationEngine.transitionNearAndClear(
                        coordinate: manualBackup,
                        pairingPath: pairingPath,
                        deviceIP: deviceIP
                    )
                }
                return LocationEngine.clear(
                    pairingPath: pairingPath,
                    deviceIP: deviceIP
                )
            }.value
            guard restoreGeneration == simulationGeneration else { return }

            switch cleared {
            case .failure(let error):
                isBusy = false
                status = .restoreFailed(error.localizedDescription)
                lastError = error.localizedDescription
                restoreDetail = String(localized: "DVT clear failed; no new location was injected.")
                return

            case .success:
                status = .waitingForRealLocation
                restoreDetail = String(localized: "Checking fresh locations for up to 30 seconds…")
                let first = await recoveryMonitor.observe(
                    previousSimulated: oldSimulated,
                    timeout: 30
                )
                guard restoreGeneration == simulationGeneration else { return }
                NSLog("[Locus] First post-clear observation: %@", describe(first.outcome))

                switch first.outcome {
                case .stable(let fix):
                    finishRestore(verified: fix, usedRescue: false)

                case .oscillating(let candidate):
                    guard allowSmartRescue,
                          LocalDevVPN.isConnected,
                          Date().timeIntervalSince(candidate.timestamp) <= 5 else {
                        finishRestore(verified: nil, usedRescue: false)
                        return
                    }

                    status = .restoring
                    restoreDetail = String(localized: "Old and new locations alternate; attempting one nearby transition…")
                    // Do not mark the candidate as trusted yet. It merely
                    // provides a plausible rescue waypoint, not verified GPS.
                    let rescued = await Task.detached(priority: .userInitiated) {
                        LocationEngine.transitionNearAndClear(
                            coordinate: candidate.coordinate,
                            pairingPath: pairingPath,
                            deviceIP: deviceIP
                        )
                    }.value
                    guard restoreGeneration == simulationGeneration else { return }

                    switch rescued {
                    case .success:
                        status = .waitingForRealLocation
                        restoreDetail = String(localized: "Checking location again after nearby transition…")
                        let second = await recoveryMonitor.observe(
                            previousSimulated: oldSimulated,
                            timeout: 20
                        )
                        guard restoreGeneration == simulationGeneration else { return }
                        NSLog("[Locus] Second post-clear observation: %@", describe(second.outcome))
                        if case .stable(let fix) = second.outcome {
                            finishRestore(verified: fix, usedRescue: true)
                        } else {
                            finishRestore(verified: nil, usedRescue: true)
                        }

                    case .failure(let error):
                        NSLog("[Locus] Nearby rescue failed: %@", error.localizedDescription)
                        // The first DVT clear succeeded. We cannot infer
                        // restoration failed globally from this second error.
                        finishRestore(verified: nil, usedRescue: true)
                        restoreDetail = String(localized: "Nearby recovery failed; the real position remains unconfirmed.")
                    }

                case .unconfirmed:
                    // No trustworthy candidate => do NOT re-inject a guessed
                    // or stale coordinate. Report uncertainty honestly.
                    finishRestore(verified: nil, usedRescue: false)
                }
            }
        }
    }

    private func describe(_ outcome: RecoveryLocationMonitor.Outcome) -> String {
        switch outcome {
        case .stable: return "stable-candidate"
        case .oscillating: return "old-new-oscillation"
        case .unconfirmed: return "unconfirmed"
        }
    }

    private func finishRestore(verified: CLLocation?, usedRescue: Bool) {
        isBusy = false
        simulated = nil
        endBackground()
        locationKeeper.refresh()

        if let verified {
            realLocationStore.acceptConfirmedRecovery(verified)
            status = .restored
            restoreDetail = usedRescue
                ? String(localized: "A fresh location was confirmed after one nearby transition. Other apps may refresh later.")
                : String(localized: "A fresh location was confirmed locally. Other apps may refresh later.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.status == .restored else { return }
                self.status = .idle
            }
        } else {
            // Do NOT thaw RealLocationStore: if the OS still uses the spoof
            // location its subsequent callbacks must not poison auto location.
            status = .restoreUnconfirmed
            restoreDetail = usedRescue
                ? String(localized: "Still unable to verify real location after nearby transition. No further attempts were made.")
                : String(localized: "Unable to verify real location. No second simulation was attempted.")
        }
    }

    /// Quiesce Locus before SideStore installs an update. Unlike normal Stop,
    /// this never opens a fresh clear-only DVT session after teardown.
    /// If a spoof is active, clear it first; then retire all timers/tasks and
    /// release every remaining RemotePairing/DVT handle.
    func prepareForUpdate(pairing: PairingStore) async -> Result<Void, LocationEngineError> {
        guard !isPreparingForUpdate else { return .success(()) }
        guard !isBusy else { return .failure(.notActive) }
        isPreparingForUpdate = true
        simulationGeneration &+= 1
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()

        let shouldClear = simulated != nil || LocationEngine.isSessionActive
        let pairingPath = pairing.pairingPath
        let deviceIP = TunnelConfig.targetIP

        let result = await Task.detached(priority: .userInitiated) {
            if shouldClear, !pairingPath.isEmpty {
                let clearResult = LocationEngine.clear(pairingPath: pairingPath, deviceIP: deviceIP)
                if case .failure = clearResult {
                    LocationEngine.releaseForUpdate()
                    return clearResult
                }
            }
            LocationEngine.releaseForUpdate()
            return Result<Void, LocationEngineError>.success(())
        }.value

        if case .success = result {
            simulated = nil
            status = .idle
            isBusy = false
            endBackground()
            locationKeeper.stop()
        }
        isPreparingForUpdate = false
        return result
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
        realLocationStore.startCaptureIfNeeded()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            await MainActor.run {
                self.apply(previous, pairing: pairing, markRecent: true)
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.apply(coord, pairing: pairing, markRecent: false)
                    }
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        guard status != .restoring && status != .waitingForRealLocation else { return }
        // Route playback and joystick can bypass teleport(), so freeze before
        // every first injection, not only at the teleport button.
        if simulated == nil { realLocationStore.freezeBeforeSimulation() }
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let injectionCoordinate = ChinaCoordinateTransform.injectionCoordinate(from: coordinate)
        if ChinaCoordinateTransform.isInMainlandChina(coordinate) {
            NSLog(
                "[Locus] China coordinate correction: map %.7f, %.7f -> injection %.7f, %.7f",
                coordinate.latitude,
                coordinate.longitude,
                injectionCoordinate.latitude,
                injectionCoordinate.longitude
            )
        }
        let result = LocationEngine.set(
            latitude: injectionCoordinate.latitude,
            longitude: injectionCoordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            beginBackground()
            locationKeeper.start()
            startResend(pairing: pairing)
            startHealth(pairing: pairing)
            if markRecent {
                pushRecent(coordinate)
            }
        case .failure(let error):
            lastError = error.localizedDescription
            if simulated != nil {
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            } else {
                status = .idle
                realLocationStore.resumeAfterFailedSimulationStart()
            }
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        let generation = simulationGeneration
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      generation == self.simulationGeneration,
                      case .active = self.status,
                      let sim = self.simulated else { return }

                let injectionCoordinate = ChinaCoordinateTransform.injectionCoordinate(from: sim)

                // Last gate before entering LocationEngine's serial queue.
                // Stop/restore increments simulationGeneration first, so a
                // queued tick from the old run cannot resurrect simulation.
                guard generation == self.simulationGeneration else { return }
                _ = LocationEngine.set(
                    latitude: injectionCoordinate.latitude,
                    longitude: injectionCoordinate.longitude,
                    pairingPath: pairing.pairingPath,
                    deviceIP: TunnelConfig.targetIP
                )
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        healthTimer?.invalidate()
        let generation = simulationGeneration
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      generation == self.simulationGeneration,
                      let sim = self.simulated else { return }

                if case .dropped = self.status {
                    guard generation == self.simulationGeneration else { return }
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                } else if case .active = self.status, !LocationEngine.isSessionActive {
                    guard generation == self.simulationGeneration else { return }
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}


struct MapFocusRequest: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: MapFocusRequest, rhs: MapFocusRequest) -> Bool {
        lhs.id == rhs.id
    }
}
