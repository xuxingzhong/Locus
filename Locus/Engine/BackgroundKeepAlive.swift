import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownLocation: CLLocation?
    private var restoreCheckStartedAt: Date?
    private var restoreFixCount = 0

    var lastKnownCoordinate: CLLocationCoordinate2D? { lastKnownLocation?.coordinate }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func refresh() {
        // Bounce our own CoreLocation stream and capture a few post-clear fixes.
        // This cannot flush or validate another app's independently held fixes.
        restoreCheckStartedAt = Date()
        restoreFixCount = 0
        manager.stopUpdatingLocation()
        lastKnownLocation = nil
        NSLog("[Locus] Restarting own CoreLocation updates after DVT clear")
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        lastKnownLocation = fix

        guard let startedAt = restoreCheckStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= 20 else {
            restoreCheckStartedAt = nil
            return
        }

        restoreFixCount += 1
        let simulated = fix.sourceInformation?.isSimulatedBySoftware
        let simulatedLabel = simulated.map { $0 ? "yes" : "no" } ?? "unknown"
        NSLog(
            "[Locus] Post-clear fix %d: age=%.1fs accuracy=%.0fm softwareSimulated=%@ (app-local only)",
            restoreFixCount,
            Date().timeIntervalSince(fix.timestamp),
            fix.horizontalAccuracy,
            simulatedLabel
        )
        if restoreFixCount >= 5 {
            restoreCheckStartedAt = nil
        }
    }
}
