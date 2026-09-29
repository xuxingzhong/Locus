import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let interfaceIP = (options?["TunnelIfaceIP"] as? String) ?? "10.7.0.2"
        let peerIP = (options?["TunnelPeerIP"] as? String) ?? "10.7.0.1"

        let ipv4 = NEIPv4Settings(addresses: [interfaceIP], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peerIP, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerIP)
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard error == nil else { completionHandler(error); return }
            self?.pumpPackets()
            completionHandler(nil)
        }
    }

    private func pumpPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var modified = packets
            for index in modified.indices where protocols[index].int32Value == AF_INET && modified[index].count >= 20 {
                modified[index].withUnsafeMutableBytes { bytes in
                    guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    let source = ptr[3]
                    ptr[3] = ptr[4]
                    ptr[4] = source
                }
            }
            self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.pumpPackets()
        }
    }
}
