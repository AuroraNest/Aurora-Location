// Derived in part from Locus, Copyright (c) 2026 Locus contributors, MIT.
import Foundation
import idevice

enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.dvt", qos: .userInitiated)
    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var server: OpaquePointer?
    private static var simulation: OpaquePointer?

    static func perform(_ command: LocationCommand?, pairingPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
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
            // FFI messages can contain peer data. Diagnostics expose only our fixed error code.
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
