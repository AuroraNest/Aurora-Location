// Derived in part from Locus, Copyright (c) 2026 Locus contributors, MIT.
import Foundation
import idevice

enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.dvt", qos: .userInitiated)
    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var server: OpaquePointer?
    private static var simulation: OpaquePointer?
    private static var failureDetails = ""

    static func perform(_ command: LocationCommand?, pairingPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                failureDetails = ""
                do {
                    if case .set(let coordinate) = command, !coordinate.isValid {
                        throw AuroraLocationError.invalidCoordinate
                    }
                    // DVT requires a live connection for the simulated location to persist.
                    // A failed command invalidates the retained session; the next attempt reconnects.
                    let openedSession = simulation == nil
                    if openedSession { try connect(pairingPath: pairingPath) }
                    switch command {
                    case .set(let coordinate):
                        try checked(location_simulation_set(simulation, coordinate.latitude, coordinate.longitude),
                            as: .locationSimulationFailed)
                    case .clear:
                        try checked(location_simulation_clear(simulation), as: .clearSimulationFailed)
                        cleanup()
                    case nil:
                        if openedSession { cleanup() }
                    }
                    continuation.resume()
                } catch {
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                cleanup()
                continuation.resume()
            }
        }
    }

    static func lastFailureDetails() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: failureDetails) }
        }
    }

    private static func connect(pairingPath: String) throws {
        idevice_set_global_timeout(10)
        var pairing: OpaquePointer?
        try checked(pairingPath.withCString { rp_pairing_file_read($0, &pairing) }, as: .pairingInvalid)
        guard let pairing else { throw AuroraLocationError.pairingInvalid }
        defer { rp_pairing_file_free(pairing) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        guard NetworkStatus.tunnelIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw AuroraLocationError.tunnelUnavailable
        }
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                    "Aurora Location", pairing, nil, nil, &adapter, &handshake)
            }
        }
        try checked(error, as: .tunnelUnavailable)
        try checked(remote_server_connect_rsd(adapter, handshake, &server), as: .dvtConnectionFailed)
        try checked(location_simulation_new(server, &simulation), as: .developerImageUnavailable)
    }

    private static func checked(_ error: UnsafeMutablePointer<IdeviceFfiError>?, as failure: AuroraLocationError) throws {
        if let error {
            // Raw peer messages may contain private data. Expose only numeric codes and fixed categories.
            let message = error.pointee.message.flatMap { String(validatingUTF8: $0) }?.lowercased() ?? ""
            let category: String
            if message.contains("connection refused") || message.contains("connectionrefused") { category = "连接被拒绝" }
            else if message.contains("timeout") || message.contains("timed out") || message.contains("timedout") { category = "超时" }
            else if message.contains("connection reset") || message.contains("connectionreset") { category = "连接被复位" }
            else if message.contains("unexpectedeof") || message.contains("failed to fill whole buffer") { category = "连接提前关闭" }
            else if message.contains("networkunreachable") || message.contains("network is unreachable") { category = "网络不可达" }
            else if message.contains("hostunreachable") || message.contains("no route to host") { category = "主机不可达" }
            else if message.contains("notconnected") || message.contains("not connected") { category = "连接已断开" }
            else if message.contains("brokenpipe") || message.contains("broken pipe") { category = "连接写入中断" }
            else if message.contains("permissiondenied") || message.contains("permission denied") { category = "系统拒绝访问" }
            else { category = "其他协议错误" }
            failureDetails = "\(failure.rawValue): \(category), code \(error.pointee.code), sub \(error.pointee.sub_code)"
            idevice_error_free(error)
            throw failure
        }
    }

    private static func cleanup() {
        // LocationSimulation BORROWS RemoteServer. Free in reverse dependency order.
        if let simulation { location_simulation_free(simulation) }
        simulation = nil
        if let server { remote_server_free(server) }
        server = nil
        if let handshake { rsd_handshake_free(handshake) }
        handshake = nil
        if let adapter { adapter_free(adapter) }
        adapter = nil
    }
}
