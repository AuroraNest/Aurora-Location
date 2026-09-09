import Foundation

enum NetworkStatus {
    static let tunnelIP = "10.7.0.1"
    static let hasWiFiAddress = false
}

@_silgen_name("aurora_test_count") private func count(_ index: Int32) -> Int32
@_silgen_name("aurora_test_fail_set") private func failNextSet()

@main
struct EngineSessionCheck {
    static func main() async throws {
        let path = "/test/pairing"
        try await LocationEngine.perform(.set(.timesSquare), pairingPath: path)
        assert(count(0) == 1 && count(1) == 1 && count(3) == 0)
        try await LocationEngine.perform(.set(Coordinate(latitude: 1, longitude: 2)), pairingPath: path)
        assert(count(0) == 1 && count(1) == 2 && count(3) == 0)
        try await LocationEngine.perform(nil, pairingPath: path)
        assert(count(0) == 1 && count(3) == 0)
        try await LocationEngine.perform(.clear, pairingPath: path)
        assert(count(2) == 1 && count(6) == 1)
        try await LocationEngine.perform(nil, pairingPath: path)
        assert(count(0) == 2 && count(6) == 2)
        failNextSet()
        do {
            try await LocationEngine.perform(.set(.timesSquare), pairingPath: path)
            assertionFailure("Expected failed set")
        } catch { assert(error as? AuroraLocationError == .locationSimulationFailed) }
        assert(count(0) == 3 && count(6) == 3 && count(7) == 1)
        try await LocationEngine.perform(.set(.timesSquare), pairingPath: path)
        assert(count(0) == 4 && count(6) == 3)
        await LocationEngine.disconnect()
        await LocationEngine.disconnect()
        assert(count(6) == 4)
        print("PASS: set retains session, next set reuses it, check preserves it, clear/failure clean up, retry reconnects; no Wi-Fi gate")
    }
}
