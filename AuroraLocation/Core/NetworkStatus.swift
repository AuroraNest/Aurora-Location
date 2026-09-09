import Foundation
import Network

enum NetworkStatus {
    static let tunnelIP = "10.7.0.1"

    static var hasWiFiAddress: Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return false }
        defer { freeifaddrs(addresses) }
        var current = addresses
        while let entry = current {
            let item = entry.pointee
            if String(cString: item.ifa_name) == "en0",
               item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
               let address = item.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET) ||
                address.pointee.sa_family == sa_family_t(AF_INET6) {
                return true
            }
            current = item.ifa_next
        }
        return false
    }

    static func probeTunnel() async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(tunnelIP), port: 49152, using: .tcp)
            let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.probe")
            // All completion paths run on this queue, so the continuation resumes once.
            var completed = false
            let finish: (Bool) -> Void = { reachable in
                guard !completed else { return }
                completed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(false) }
        }
    }
}
