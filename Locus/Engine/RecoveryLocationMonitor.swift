import CoreLocation
import Foundation

/// Observes CoreLocation AFTER a DVT clear. Neither a successful clear nor a
/// CoreLocation flag is proof of real GPS; this classifier deliberately favors
/// "unconfirmed" over accepting a stale simulated fix.
@MainActor
final class RecoveryLocationMonitor: NSObject, CLLocationManagerDelegate {
    enum Outcome {
        case stable(CLLocation)
        case oscillating(CLLocation)
        case unconfirmed
    }

    struct Observation {
        let outcome: Outcome
        let totalFixes: Int
        let freshCandidates: Int
        let oldSimulatedFixes: Int
    }

    private struct Sample {
        let fix: CLLocation
        let oldSimulation: Bool
        let candidate: Bool
    }

    private let manager = CLLocationManager()
    private var samples: [Sample] = []
    private var lastSimulated: CLLocation?
    private var startedAt = Date()
    private var observing = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func observe(
        previousSimulated: CLLocationCoordinate2D?,
        timeout: TimeInterval = 30
    ) async -> Observation {
        guard manager.authorizationStatus == .authorizedAlways ||
              manager.authorizationStatus == .authorizedWhenInUse,
              manager.accuracyAuthorization == .fullAccuracy else {
            NSLog("[Locus] Post-clear observation unavailable: location permission or precision")
            return Observation(outcome: .unconfirmed, totalFixes: 0, freshCandidates: 0, oldSimulatedFixes: 0)
        }

        samples = []
        lastSimulated = previousSimulated.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        startedAt = Date()
        observing = true
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
        defer {
            observing = false
            manager.stopUpdatingLocation()
        }

        let deadline = startedAt.addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let elapsed = Date().timeIntervalSince(startedAt)
            // Observe for a full 15 seconds even if early readings look good:
            // an older DVT fix may bounce back after a few seconds.
            if elapsed >= 15, case .stable = classify() { break }
            // A repeatable real-position cluster and old fake fixes alternated.
            // Do not wait the whole timeout before a one-time rescue attempt.
            if elapsed >= 18, case .oscillating = classify() { break }
        }

        let outcome = classify()
        let validCount = samples.filter(\.candidate).count
        let oldCount = samples.filter(\.oldSimulation).count
        NSLog(
            "[Locus] Post-clear observation fixes=%d candidates=%d oldOrSimulated=%d",
            samples.count, validCount, oldCount
        )
        return Observation(
            outcome: outcome,
            totalFixes: samples.count,
            freshCandidates: validCount,
            oldSimulatedFixes: oldCount
        )
    }

    private func classify() -> Outcome {
        let now = Date()
        let recent = samples.filter { now.timeIntervalSince($0.fix.timestamp) <= 15 }
        let valid = recent.filter(\.candidate).map(\.fix)
        guard let latest = valid.last,
              now.timeIntervalSince(latest.timestamp) <= 5 else {
            return .unconfirmed
        }

        // Candidate fixes must describe a plausible moving phone, not a
        // location jumping across cities. Keep this conservative for driving.
        func coherent(_ fixes: [CLLocation]) -> Bool {
            guard fixes.count >= 2 else { return false }
            for i in 1..<fixes.count {
                let elapsed = fixes[i].timestamp.timeIntervalSince(fixes[i - 1].timestamp)
                guard elapsed > 0 else { return false }
                let allowance = max(
                    150,
                    45 * elapsed + fixes[i].horizontalAccuracy + fixes[i - 1].horizontalAccuracy
                )
                if fixes[i].distance(from: fixes[i - 1]) > allowance { return false }
            }
            return true
        }

        let windowHasOld = recent.contains(where: { $0.oldSimulation })
        if valid.count >= 5,
           let first = valid.first,
           latest.timestamp.timeIntervalSince(first.timestamp) >= 10,
           coherent(valid),
           !windowHasOld {
            return .stable(latest)
        }

        // Rescue ONLY when we observed alternating old mocked fixes and a
        // consistent, independently refreshing candidate cluster.
        if windowHasOld, valid.count >= 3,
           let first = valid.first,
           latest.timestamp.timeIntervalSince(first.timestamp) >= 5,
           coherent(valid) {
            return .oscillating(latest)
        }

        return .unconfirmed
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            self?.collect(locations)
        }
    }

    private func collect(_ locations: [CLLocation]) {
        guard observing else { return }
        for fix in locations {
            guard CLLocationCoordinate2DIsValid(fix.coordinate),
                  fix.timestamp >= startedAt,
                  abs(fix.timestamp.timeIntervalSinceNow) <= 5 else { continue }

            // Do not count a repeated cached timestamp as another GPS fix.
            if let previous = samples.last,
               fix.timestamp.timeIntervalSince(previous.fix.timestamp) < 0.8 { continue }

            let softwareSimulated = fix.sourceInformation?.isSimulatedBySoftware == true
            let accessoryProduced = fix.sourceInformation?.isProducedByAccessory == true
            let distanceFromFake = lastSimulated.map { fix.distance(from: $0) }
            let matchesOldFake = distanceFromFake.map {
                $0 <= max(150, fix.horizontalAccuracy * 2)
            } ?? false

            let validSource = fix.sourceInformation != nil &&
                !softwareSimulated && !accessoryProduced
            let qualityOK = fix.horizontalAccuracy > 0 &&
                fix.horizontalAccuracy <= 100 &&
                manager.accuracyAuthorization == .fullAccuracy

            samples.append(Sample(
                fix: fix,
                oldSimulation: softwareSimulated || matchesOldFake,
                candidate: validSource && qualityOK && !matchesOldFake
            ))
            if samples.count > 90 { samples.removeFirst(samples.count - 90) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Locus] Post-clear location error: %@", error.localizedDescription)
    }
}
