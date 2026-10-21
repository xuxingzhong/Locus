import CoreLocation
import Foundation

/// A user-editable recovery waypoint. Automatic fixes are collected only
/// before a Locus simulation starts, never from the simulated CoreLocation
/// stream. This is a best-effort waypoint, not independent raw GPS.
@MainActor
final class RealLocationStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RealLocationStore()
    static let smoothRestoreKey = "locus.restore.useNearbyTransition"

    struct SavedPoint: Codable, Equatable {
        enum Source: String, Codable {
            case automatic
            case manual
        }

        var latitude: Double
        var longitude: Double
        var address: String
        var capturedAt: Date
        var horizontalAccuracy: Double?
        var source: Source

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    @Published private(set) var saved: SavedPoint?
    @Published private(set) var isLocating = false
    @Published private(set) var captureMessage: String?

    private let storageKey = "locus.restore.savedRealLocation.v1"
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var candidate: CLLocation?
    private var frozen = false
    private var allowManualReplacement = false

    /// An automatic snapshot cannot be assumed to describe a moving phone
    /// indefinitely. Manual coordinates are explicitly maintained by the user.
    private let maximumAutomaticAge: TimeInterval = 30 * 60

    override init() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            saved = try? JSONDecoder().decode(SavedPoint.self, from: data)
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var canUseForRecovery: Bool {
        guard let saved, CLLocationCoordinate2DIsValid(saved.coordinate) else { return false }
        if saved.source == .manual { return true }
        let age = Date().timeIntervalSince(saved.capturedAt)
        return age >= 0 && age <= maximumAutomaticAge
    }

    var recoveryCoordinate: CLLocationCoordinate2D? {
        canUseForRecovery ? saved?.coordinate : nil
    }

    var isAutomaticSnapshotExpired: Bool {
        guard saved?.source == .automatic else { return false }
        return !canUseForRecovery
    }

    /// Called when the map first appears. Never silently replace a manual
    /// point, or thaw a capture stream previously frozen by simulation.
    func startCaptureIfNeeded() {
        guard !frozen, saved?.source != .manual else { return }
        startAuthorizedCapture()
    }

    /// Explicit user action only, enabled in Settings when no simulation is
    /// reported. The user can recapture after a completed restore.
    func requestFreshCapture() {
        frozen = false
        allowManualReplacement = true
        candidate = nil
        captureMessage = nil
        startAuthorizedCapture()
    }

    func freezeBeforeSimulation() {
        frozen = true
        candidate = nil
        allowManualReplacement = false
        manager.stopUpdatingLocation()
        isLocating = false
    }

    func resumeAfterFailedSimulationStart() {
        frozen = false
        startCaptureIfNeeded()
    }

    func saveManual(coordinate: CLLocationCoordinate2D, address: String) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        freezeBeforeSimulation()
        saved = SavedPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: trimmed,
            capturedAt: Date(),
            horizontalAccuracy: nil,
            source: .manual
        )
        persist()
        captureMessage = nil
        NSLog("[Locus] Recovery location manually updated")
    }

    private func startAuthorizedCapture() {
        guard !frozen, !isLocating else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard manager.accuracyAuthorization == .fullAccuracy else {
                captureMessage = String(localized: "Precise Location is required to capture a real position.")
                return
            }
            isLocating = true
            captureMessage = nil
            manager.startUpdatingLocation()
        case .denied, .restricted:
            captureMessage = String(localized: "Enable location access in iOS Settings or choose an address manually.")
        @unknown default:
            break
        }
    }

    private func persist() {
        guard let saved, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard !frozen, isLocating else { return }
        for fix in locations {
            guard fix.horizontalAccuracy > 0,
                  fix.horizontalAccuracy <= 100,
                  CLLocationCoordinate2DIsValid(fix.coordinate),
                  abs(fix.timestamp.timeIntervalSinceNow) <= 15,
                  manager.accuracyAuthorization == .fullAccuracy,
                  let source = fix.sourceInformation,
                  !source.isSimulatedBySoftware,
                  !source.isProducedByAccessory else {
                continue
            }

            // Two independent recent, nearby fixes are more useful than one
            // cached response. This is still only a confidence heuristic.
            if let previous = candidate,
               fix.distance(from: previous) <= max(100, fix.horizontalAccuracy + previous.horizontalAccuracy) {
                let previousSave = saved
                let point = SavedPoint(
                    latitude: fix.coordinate.latitude,
                    longitude: fix.coordinate.longitude,
                    address: String(localized: "Current position (resolving address…)"),
                    capturedAt: fix.timestamp,
                    horizontalAccuracy: fix.horizontalAccuracy,
                    source: .automatic
                )
                // No new auto-fix may overwrite a manually chosen position
                // unless its owner explicitly pressed "Capture current position".
                if previousSave?.source != .manual || allowManualReplacement {
                    saved = point
                    persist()
                    resolveAddress(for: point)
                    NSLog("[Locus] Saved pre-simulation real location, accuracy %.0fm", fix.horizontalAccuracy)
                }
                allowManualReplacement = false
                candidate = nil
                manager.stopUpdatingLocation()
                isLocating = false
                return
            }
            candidate = fix
        }
    }

    private func resolveAddress(for point: SavedPoint) {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        Task { [weak self] in
            guard let self else { return }
            let marks = try? await self.geocoder.reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "zh-Hans")
            )
            guard let placemark = marks?.first, var current = self.saved,
                  current.source == .automatic,
                  current.capturedAt == point.capturedAt else { return }

            var parts: [String] = []
            for part in [placemark.locality, placemark.subLocality, placemark.thoroughfare, placemark.name] {
                guard let part, !part.isEmpty, !parts.contains(part) else { continue }
                parts.append(part)
            }
            let address = parts.joined(separator: " ")
            if !address.isEmpty {
                current.address = address
                self.saved = current
                self.persist()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.startAuthorizedCapture() }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in self?.handleLocations(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isLocating = false
            self?.captureMessage = error.localizedDescription
        }
    }
}
