import Foundation

@main struct LocalTunnelPacketCheck {
    static func main() {
        var packet = Data(repeating: 0, count: 40)
        packet[0] = 0x45
        packet[3] = 40
        packet[8] = 64
        packet[9] = 6
        packet[10] = 0x12
        packet[11] = 0x34
        packet.replaceSubrange(12..<16, with: [10, 7, 0, 10])
        packet.replaceSubrange(16..<20, with: [10, 7, 0, 1])
        packet[32] = 0x50
        packet[33] = 2
        let reflected = PacketTunnelProvider.reflectedIPv4Packet(packet)!
        assert(Array(reflected[12..<16]) == [10, 7, 0, 1])
        assert(Array(reflected[16..<20]) == [10, 7, 0, 10])
        assert(reflected.prefix(12) == packet.prefix(12) && reflected.suffix(20) == packet.suffix(20))
        assert(PacketTunnelProvider.reflectedIPv4Packet(reflected) == packet)
        assert(PacketTunnelProvider.reflectedIPv4Packet(Data(packet.prefix(19))) == nil)
        for (offset, value) in [(0, UInt8(0x65)), (0, 0x44), (3, 41), (9, 17), (16, 8), (12, 8)] {
            var invalid = packet
            invalid[offset] = value
            assert(PacketTunnelProvider.reflectedIPv4Packet(invalid) == nil)
        }
        // IP fragments retain their flags and payload; reflection does not inspect TCP sequence state.
        packet[6] = 0x20
        assert(PacketTunnelProvider.reflectedIPv4Packet(packet)?[6] == 0x20)
        print("PASS: local tunnel IPv4 reflection, both directions, unchanged checksums/payload and invalid input rejection")
    }
}
