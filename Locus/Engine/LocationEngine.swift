import CoreLocation
import Foundation
import Network
import idevice

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive

    var errorDescription: String? {
        switch self {
        case .invalidIP: return String(localized: "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1).")
        case .pairingRead: return String(localized: "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode.")
        case .tunnelCreate: return String(localized: "Could not open the developer tunnel. Is LocalDevVPN connected on Wi‑Fi?")
        case .remoteServer: return String(localized: "Connected to the tunnel but RemoteXPC handshake failed.")
        case .simulationCreate: return String(localized: "Could not open Apple’s location simulation service.")
        case .locationSet: return String(localized: "Failed to set simulated coordinates.")
        case .locationClear: return String(localized: "Failed to clear simulated location.")
        case .notActive: return String(localized: "No active simulation session.")
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12
    private static let fallbackRemotePairingPort: UInt16 = 49152
    private static var _lastRemotePairingPort: UInt16?

    /// Most recently discovered/used _remotepairing._tcp port.
    static var lastRemotePairingPort: UInt16? {
        queue.sync { _lastRemotePairingPort }
    }

    static var isSessionActive: Bool { queue.sync { locationSimulation != nil } }

    /// Release every RemotePairing/DVT handle without creating a new session.
    /// Used before handing an IPA to SideStore so Locus cannot compete for the
    /// same device gateway while SideStore installs the update.
    static func releaseForUpdate() {
        queue.sync { cleanup() }
    }

    static func refreshRemotePairingPort() -> UInt16? {
        queue.sync {
            let port = discoverRemotePairingPort(timeout: 3.0)
            if let port { _lastRemotePairingPort = port }
            return port
        }
    }

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.locationSet)
        queue.sync {
            let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    static func clear(
        pairingPath: String,
        deviceIP: String,
        settlingNear: CLLocationCoordinate2D? = nil
    ) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.locationClear)
        queue.sync {
            // Clear on the same DVT channel that installed the simulation
            // BEFORE dropping it. The location simulation service is
            // connection-scoped; a successful clear on a fresh channel is not
            // guaranteed to tear down a still-active previous channel.
            // If the original channel is gone or rejects the clear, fall back
            // to the standalone fresh-session clear used by pymobiledevice3.
            let startedAt = Date()
            let hadLiveSession = locationSimulation != nil
            NSLog("[Locus] DVT restore started; hadLiveSession=%@", hadLiveSession ? "yes" : "no")

            let code: Int32
            if hadLiveSession {
                let activeCode = clearLocked(settlingNear: settlingNear)
                if activeCode == ok {
                    NSLog("[Locus] DVT clear succeeded on original location session")
                    code = ok
                } else {
                    NSLog("[Locus] Original DVT clear failed code=%d; using fresh-session fallback", activeCode)
                    code = clearWithFreshSessionLocked(pairingPath: pairingPath, deviceIP: deviceIP)
                }
            } else {
                // No active session (e.g. app relaunched): still allow the
                // user to send a standalone clear without first teleporting.
                cleanup()
                code = clearWithFreshSessionLocked(pairingPath: pairingPath, deviceIP: deviceIP)
            }

            NSLog(
                "[Locus] DVT restore finished code=%d duration=%.2fs; clear return does not confirm other apps",
                code,
                Date().timeIntervalSince(startedAt)
            )
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    /// One bounded post-clear rescue: simulate at a newly observed nearby
    /// candidate on a fresh DVT channel, hold 8 seconds, then clear that SAME
    /// channel. Do not use stale saved/manual points in this automatic path.
    /// All FFI operations are serialized, so timer callbacks cannot interleave.
    static func transitionNearAndClear(
        coordinate: CLLocationCoordinate2D,
        pairingPath: String,
        deviceIP: String
    ) -> Result<Void, LocationEngineError> {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return .failure(.locationSet)
        }
        let target = ChinaCoordinateTransform.injectionCoordinate(from: coordinate)
        var result: Result<Void, LocationEngineError> = .failure(.locationSet)
        queue.sync {
            NSLog("[Locus] Starting one-time post-clear nearby transition")
            let setCode = setLocked(
                latitude: target.latitude, longitude: target.longitude,
                pairingPath: pairingPath, deviceIP: deviceIP
            )
            guard setCode == ok else {
                result = .failure(.from(code: setCode))
                return
            }
            Thread.sleep(forTimeInterval: 8.0)
            let clearCode = clearLocked(settlingNear: nil)
            if clearCode == ok {
                result = .success(())
            } else {
                // The original channel was released on failure. Try one
                // standalone clear so we do not leave our rescue simulation up.
                let fallback = clearWithFreshSessionLocked(
                    pairingPath: pairingPath, deviceIP: deviceIP
                )
                result = fallback == ok
                    ? .success(())
                    : .failure(.from(code: fallback))
            }
            NSLog("[Locus] One-time transition/clear finished")
        }
        return result
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        func connectAndSet(discoveryTimeout: TimeInterval) -> Int32 {
            cleanup()

            // Prefer the live Bonjour port. Only use the historical port after
            // discovery has had a chance to finish.
            let remotePairingPort = discoverRemotePairingPort(timeout: discoveryTimeout) ?? fallbackRemotePairingPort
            _lastRemotePairingPort = remotePairingPort
            NSLog("[Locus] Remote Pairing port: %u", remotePairingPort)

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(remotePairingPort).bigEndian
            let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            guard inetResult == 1 else { return invalidIP }

            let tunnelError = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        "LocusLocation",
                        pairingHandle,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
            if let tunnelError {
                idevice_error_free(tunnelError)
                cleanup()
                return tunnelCreate
            }

            if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
                idevice_error_free(remoteServerError)
                cleanup()
                return remoteServerCode
            }

            if let simError = location_simulation_new(remoteServer, &locationSimulation) {
                idevice_error_free(simError)
                cleanup()
                return simulationCreate
            }
            remoteServer = nil

            if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(setError)
                cleanup()
                return locationSet
            }
            return ok
        }

        let firstCode = connectAndSet(discoveryTimeout: 2.5)
        guard firstCode != ok else { return ok }
        guard firstCode != invalidIP && firstCode != pairingRead else { return firstCode }

        // The Remote Pairing advertisement/tunnel can still be warming up on
        // the first teleport. Retry the complete connection chain rather than
        // only recreating the tunnel.
        NSLog("[Locus] Initial location session failed with code %d; retrying full session", firstCode)
        Thread.sleep(forTimeInterval: 1.0)
        return connectAndSet(discoveryTimeout: 3.5)
    }

    /// Resolve the current Bonjour Remote Pairing service instead of assuming
    /// Apple's historical 49152 port. LocalDevVPN exposes the device through
    /// 10.7.0.1 while Bonjour advertises the actual, potentially dynamic port.
    private static func discoverRemotePairingPort(timeout: TimeInterval) -> UInt16? {
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing._tcp", domain: "local."),
            using: .tcp
        )
        let browserQueue = DispatchQueue(label: "com.chrismack.locus.remotepairing")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolvedPort: UInt16?
        var finished = false

        func finish(_ port: UInt16?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if let port { resolvedPort = port }
            finished = true
            semaphore.signal()
        }

        browser.stateUpdateHandler = { state in
            if case .failed = state { finish(nil) }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case let .service(name: _, type: _, domain: _, interface: _) = result.endpoint {
                    let connection = NWConnection(to: result.endpoint, using: .tcp)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let path = connection.currentPath,
                               case let .hostPort(_, port) = path.remoteEndpoint {
                                let value = port.rawValue
                                connection.cancel()
                                finish(value)
                            }
                        case .failed:
                            connection.cancel()
                        default:
                            break
                        }
                    }
                    connection.start(queue: browserQueue)
                }
            }
        }

        browser.start(queue: browserQueue)
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()

        lock.lock()
        defer { lock.unlock() }
        return resolvedPort
    }

    private static func clearWithFreshSessionLocked(pairingPath: String, deviceIP: String) -> Int32 {
        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        func connectAndClear(discoveryTimeout: TimeInterval) -> Int32 {
            cleanup()

            let remotePairingPort = discoverRemotePairingPort(timeout: discoveryTimeout)
                ?? _lastRemotePairingPort
                ?? fallbackRemotePairingPort
            _lastRemotePairingPort = remotePairingPort
            NSLog("[Locus] Restore real location using Remote Pairing port: %u", remotePairingPort)

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(remotePairingPort).bigEndian
            let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            guard inetResult == 1 else { return invalidIP }

            let tunnelError = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        "LocusLocationClear",
                        pairingHandle,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
            if let tunnelError {
                idevice_error_free(tunnelError)
                cleanup()
                return tunnelCreate
            }

            if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
                idevice_error_free(remoteServerError)
                cleanup()
                return remoteServerCode
            }

            if let simError = location_simulation_new(remoteServer, &locationSimulation) {
                idevice_error_free(simError)
                cleanup()
                return simulationCreate
            }
            remoteServer = nil

            guard let locationSimulation else {
                cleanup()
                return simulationCreate
            }

            // This maps directly to DVT stopLocationSimulation. Do not call
            // location_simulation_set first: restore must be a clear-only
            // command on a newly opened service channel.
            if let clearError = location_simulation_clear(locationSimulation) {
                idevice_error_free(clearError)
                cleanup()
                return locationClear
            }

            // DVT stopLocationSimulation is not a cross-app acknowledgement.
            // Give the device time to process the clear before releasing this
            // fresh channel; this is a bounded settling delay, not proof that
            // every app has discarded its old location.
            NSLog("[Locus] DVT clear sent; holding session open for 1.0s")
            Thread.sleep(forTimeInterval: 1.0)
            cleanup()
            NSLog("[Locus] DVT clear session released")
            return ok
        }

        let firstCode = connectAndClear(discoveryTimeout: 2.5)
        guard firstCode != ok else { return ok }
        guard firstCode != invalidIP && firstCode != pairingRead else { return firstCode }

        NSLog("[Locus] Initial restore session failed with code %d; retrying fresh clear session", firstCode)
        Thread.sleep(forTimeInterval: 0.5)
        return connectAndClear(discoveryTimeout: 3.5)
    }

    /// Stop simulation on the original live DVT channel before disposing it.
    /// Delay cleanup briefly so the asynchronous device-side transition can
    /// settle; this is not a guarantee that every client has a real GPS fix.
    private static func clearLocked(settlingNear: CLLocationCoordinate2D?) -> Int32 {
        guard let locationSimulation else { return locationClear }

        // Verified manually on iOS 26: reacquiring real GPS after a distant
        // spoof can improve if we first put the simulated fix near a saved
        // real-world waypoint. Only try this on the live original DVT session.
        // Never invent a waypoint or use a simulated CoreLocation callback.
        if let near = settlingNear, CLLocationCoordinate2DIsValid(near) {
            let injection = ChinaCoordinateTransform.injectionCoordinate(from: near)
            if let err = location_simulation_set(
                locationSimulation,
                injection.latitude,
                injection.longitude
            ) {
                idevice_error_free(err)
                NSLog("[Locus] Nearby transition failed; proceeding to DVT clear")
            } else {
                NSLog("[Locus] Nearby restore transition accepted; waiting 8s before clear")
                Thread.sleep(forTimeInterval: 8.0)
            }
        }

        if let err = location_simulation_clear(locationSimulation) {
            idevice_error_free(err)
            cleanup()
            return locationClear
        }
        NSLog("[Locus] Original DVT clear accepted; holding original session open for 1.0s")
        Thread.sleep(forTimeInterval: 1.0)
        cleanup()
        return ok
    }
}
