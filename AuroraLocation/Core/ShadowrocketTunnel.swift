import Foundation
import aurora_emproxy

enum ShadowrocketTunnel {
    private static let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.loopback")
    private static var handle: OpaquePointer?

    static func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard handle == nil else { continuation.resume(); return }
                    let keys = try TunnelKeys.loadOrCreate()
                    let clientPublic = try keys.clientPublicKey
                    let result = keys.serverPrivateKey.withUnsafeBytes { server in
                        clientPublic.withUnsafeBytes { client in
                            aurora_emproxy_start(server.bindMemory(to: UInt8.self).baseAddress,
                                client.bindMemory(to: UInt8.self).baseAddress, 51820, &handle)
                        }
                    }
                    guard result == 0, handle != nil else { throw AuroraLocationError.tunnelStartFailed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error as? AuroraLocationError ?? .storageFailed) }
            }
        }
    }

    static func stop() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                guard handle != nil else { continuation.resume(returning: "中继未运行"); return }
                var stats = AuroraEMProxyStats()
                let valid = aurora_emproxy_get_stats(handle, &stats) == 0
                let result = aurora_emproxy_stop(&handle)
                let summary = valid
                    ? "UDP \(stats.received_udp), 解密 \(stats.authenticated_ipv4), 回送 \(stats.reflected_ipv4), 拒绝 \(stats.rejected_packets)"
                    : "中继未运行"
                let reasons = ["无", "来源不匹配", "WireGuard 会话不存在", "WireGuard 会话索引不匹配", "WireGuard 校验失败", "IPv4 过滤", "不支持 IPv6"]
                let reason = stats.last_rejection < UInt64(reasons.count) ? reasons[Int(stats.last_rejection)] : "未知"
                let details = summary + ", TCP 复位 \(stats.tcp_resets) (49152 发出 \(stats.pairing_port_resets))" + (stats.rejected_packets > 0 ? ", 最近拒绝: " + reason : "")
                continuation.resume(returning: result == 0 ? details : details + ", 停止异常")
            }
        }
    }
}
