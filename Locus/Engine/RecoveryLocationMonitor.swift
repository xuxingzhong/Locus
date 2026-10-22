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
        let rawFixes: Int
        let staleOrDuplicateFixes: Int
        let missingSourceFixes: Int
        let poorAccuracyFixes: Int
    }

    private struct Sample {
        let fix: CLLocation
        let oldSimulation: Bool
        let candidate: Bool
        let missingSource: Bool
        let poorAccuracy: Bool
    }

    private let manager = CLLocationManager()
    private var samples: [Sample] = []
    private var lastSimulated: CLLocation?
    private var startedAt = Date()
    private var observing = false
    private var rawFixes = 0
    private var staleOrDuplicateFixes = 0

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
            return Observation(
                outcome: .unconfirmed, totalFixes: 0, freshCandidates: 0,
                oldSimulatedFixes: 0, rawFixes: 0,
                staleOrDuplicateFixes: 0, missingSourceFixes: 0,
                poorAccuracyFixes: 0
            )
        }

        samples = []
        rawFixes = 0
        staleOrDuplicateFixes = 0
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
        var restartedOnce = false
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let elapsed = Date().timeIntervalSince(startedAt)

            // Core Location does not guarantee one callback each second while
            // stationary. If no fresh fix arrives, restart ONCE to request a
            // new initial update. Do not count cached timestamps as new fixes.
            if elapsed >= 9 && !restartedOnce && samples.isEmpty {
                restartedOnce = true
                NSLog("[Locus] No new post-clear fixes after 9 seconds; restarting observation")
                manager.stopUpdatingLocation()
                manager.startUpdatingLocation()
            }

            // Keep a minimum observation period to detect a delayed old fake.
            if elapsed >= 15, case .stable = classify() { break }
            if elapsed >= 18, case .oscillating = classify() { break }
        }

        let outcome = classify()
        let validCount = samples.filter(\.candidate).count
        let oldCount = samples.filter(\.oldSimulation).count
        let noSource = samples.filter(\.missingSource).count
        let poorAccuracy = samples.filter(\.poorAccuracy).count
        NSLog(
            "[Locus] Post-clear fixes: raw=%d new=%d candidates=%d old=%d noSource=%d poorAccuracy=%d staleOrDuplicate=%d",
            rawFixes, samples.count, validCount, oldCount,
            noSource, poorAccuracy, staleOrDuplicateFixes
        )
        return Observation(
            outcome: outcome,
            totalFixes: samples.count,
            freshCandidates: validCount,
            oldSimulatedFixes: oldCount,
            rawFixes: rawFixes,
            staleOrDuplicateFixes: staleOrDuplicateFixes,
            missingSourceFixes: noSource,
            poorAccuracyFixes: poorAccuracy
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
        let reliableSourceCount = recent.filter {
            $0.candidate && !$0.missingSource
        }.count
        guard let first = valid.first else { return .unconfirmed }
        let span = latest.timestamp.timeIntervalSince(first.timestamp)
        let consistent = coherent(valid)
        // sourceInformation is nullable, and GPS callbacks are NOT periodic.
        // Explicitly simulated/accessory fixes remain rejected. A nil source
        // needs a longer multi-fix cluster than an explicitly unflagged source.
        let sufficientEvidence =
            (reliableSourceCount >= 2 && valid.count >= 2 && span >= 4)
            || (valid.count >= 3 && span >= 8)

        if sufficientEvidence && consistent && !windowHasOld {
            return .stable(latest)
        }

        // Rescue ONLY when a coherent fresh cluster alternated with old fixes.
        if windowHasOld && valid.count >= 3 && span >= 5 && consistent {
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
            rawFixes += 1
            guard CLLocationCoordinate2DIsValid(fix.coordinate),
                  fix.timestamp >= startedAt,
                  abs(fix.timestamp.timeIntervalSinceNow) <= 5 else {
                staleOrDuplicateFixes += 1
                continue
            }

            // Prevent a cached fix from masquerading as repeated GPS samples.
            if let previous = samples.last,
               fix.timestamp.timeIntervalSince(previous.fix.timestamp) < 0.8 {
                staleOrDuplicateFixes += 1
                continue
            }

            let softwareSimulated = fix.sourceInformation?.isSimulatedBySoftware == true
            let accessoryProduced = fix.sourceInformation?.isProducedByAccessory == true
            let sourceMissing = fix.sourceInformation == nil
            let distanceFromFake = lastSimulated.map { fix.distance(from: $0) }
            let matchesOldFake = distanceFromFake.map {
                $0 <= max(150, fix.horizontalAccuracy * 2)
            } ?? false

            let validSource = !softwareSimulated && !accessoryProduced
            let qualityOK = fix.horizontalAccuracy > 0 &&
                fix.horizontalAccuracy <= 100 &&
                manager.accuracyAuthorization == .fullAccuracy

            samples.append(Sample(
                fix: fix,
                oldSimulation: softwareSimulated || matchesOldFake,
                candidate: validSource && qualityOK && !matchesOldFake,
                missingSource: sourceMissing,
                poorAccuracy: !qualityOK
            ))
            if samples.count > 90 { samples.removeFirst(samples.count - 90) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Locus] Post-clear location error: %@", error.localizedDescription)
    }
}
