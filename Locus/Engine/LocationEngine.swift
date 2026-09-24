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

    static func clear() -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.notActive)
        queue.sync {
            let code = clearLocked()
            result = code == ok ? .success(()) : .failure(.from(code: code))
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

    private static func clearLocked() -> Int32 {
        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
