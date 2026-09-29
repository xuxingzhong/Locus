import Foundation
import NetworkExtension

enum EmbeddedTunnel {
    static let interfaceIP = "10.7.0.2"
    static let peerIP = "10.7.0.1"
    static let providerBundleIdentifier = "com.chrismack.locus.Tunnel"

    static func start() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        } ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "Locus Local Tunnel"
        proto.providerConfiguration = ["TunnelIfaceIP": interfaceIP, "TunnelPeerIP": peerIP]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Locus Local Tunnel"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel(options: ["TunnelIfaceIP": interfaceIP as NSString, "TunnelPeerIP": peerIP as NSString])
    }

    static func stop() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        }?.connection.stopVPNTunnel()
    }
}
