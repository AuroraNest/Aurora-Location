import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum Address {
        static let peer: [UInt8] = [10, 7, 0, 1]
        static let interface: [UInt8] = [10, 7, 0, 10]
    }

    private let stateQueue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.local-tunnel")
    private var acceptsPackets = false
    private var generation = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.10"], subnetMasks: ["255.255.255.0"])
        // This tunnel owns only the fixed developer peer. It has no default route or DNS settings.
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        stateQueue.async { [self] in
            self.generation += 1
            let generation = self.generation
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else {
                    completionHandler(error ?? LocalTunnelError.providerReleased)
                    return
                }
                guard error == nil else {
                    completionHandler(error)
                    return
                }
                self.stateQueue.async {
                    guard self.generation == generation else {
                        completionHandler(LocalTunnelError.providerReleased)
                        return
                    }
                    self.acceptsPackets = true
                    self.readNextPacketBatch(generation: generation)
                    completionHandler(nil)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stateQueue.async {
            self.acceptsPackets = false
            self.generation += 1
            completionHandler()
        }
    }

    private func readNextPacketBatch(generation: Int) {
        guard acceptsPackets, self.generation == generation else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.stateQueue.async {
                guard self.acceptsPackets, self.generation == generation else { return }
                let reflected = zip(packets, protocols).compactMap { packet, family -> Data? in
                    guard family.int32Value == AF_INET else { return nil }
                    return Self.reflectedIPv4Packet(packet)
                }
                if !reflected.isEmpty {
                    _ = self.packetFlow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count))
                }
                self.readNextPacketBatch(generation: generation)
            }
        }
    }

    static func reflectedIPv4Packet(_ packet: Data) -> Data? {
        // Byte indexing avoids unaligned loads from packets supplied by the system.
        guard packet.count >= 20,
              packet[0] >> 4 == 4,
              packet[0] & 0x0F >= 5 else {
            return nil
        }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let totalLength = Int(packet[2]) << 8 | Int(packet[3])
        guard headerLength <= totalLength,
              headerLength <= packet.count,
              totalLength == packet.count,
              packet[9] == 6 else {
            return nil
        }
        let source = Array(packet[12..<16])
        let destination = Array(packet[16..<20])
        guard (source == Address.interface && destination == Address.peer) ||
              (source == Address.peer && destination == Address.interface) else { return nil }

        var reflected = packet
        reflected.replaceSubrange(12..<16, with: destination)
        reflected.replaceSubrange(16..<20, with: source)
        // Exchanging only the two IPv4 addresses preserves the IPv4 header checksum and TCP/UDP pseudo-header checksum.
        return reflected
    }
}

private enum LocalTunnelError: LocalizedError {
    case providerReleased

    var errorDescription: String? {
        switch self {
        case .providerReleased:
            return "本地设备隧道未能完成启动."
        }
    }
}
