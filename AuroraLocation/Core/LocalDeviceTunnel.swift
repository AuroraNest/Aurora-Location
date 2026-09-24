import Foundation
import NetworkExtension

@MainActor
enum LocalDeviceTunnel {
    private static let providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".LocalTunnel"
    private static let profileDescription = "Aurora Location Local Device Tunnel"
    private static let statusTimeout = Duration.seconds(10)
    private static var manager: NETunnelProviderManager?
    private(set) static var lastFailureDetails = ""

    static var isConnected: Bool {
        guard let manager else { return false }
        return manager.connection.status == .connected
    }

    static func start() async throws {
        lastFailureDetails = ""
        do {
            try await startConfiguredTunnel()
        } catch {
            lastFailureDetails = (error as? LocalDeviceTunnelError ?? systemError(error, stage: "configuration")).localizedDescription
            DiagnosticLog.event("local.start.failed \(lastFailureDetails)")
            throw error
        }
    }

    private static func startConfiguredTunnel() async throws {
        let manager = try await loadOwnedManager(createIfMissing: true)
        DiagnosticLog.event("local.loaded status=\(manager.connection.status.rawValue)")
        if manager.connection.status == .connected { return }

        if manager.connection.status == .disconnecting {
            guard await waitForStatus(of: manager, until: { $0 == .disconnected || $0 == .invalid }) else {
                throw await timeoutError(manager)
            }
        }

        if manager.connection.status == .connecting || manager.connection.status == .reasserting {
            guard await waitForStatus(of: manager, until: { $0 == .connected }) else {
                throw await timeoutError(manager)
            }
            return
        }

        guard let session = manager.connection as? NETunnelProviderSession else {
            throw LocalDeviceTunnelError.unavailable
        }
        do {
            try session.startTunnel(options: nil)
        } catch {
            throw systemError(error, stage: "startTunnel")
        }
        guard await waitForStatus(of: manager, until: { $0 == .connected }) else {
            throw await timeoutError(manager)
        }
    }

    static func stop() async -> Bool {
        let manager: NETunnelProviderManager
        do {
            manager = try await loadOwnedManager(createIfMissing: false)
        } catch LocalDeviceTunnelError.notConfigured {
            self.manager = nil
            return true
        } catch {
            return false
        }
        guard isActive(manager.connection.status) else { return true }
        guard let session = manager.connection as? NETunnelProviderSession else { return false }
        session.stopTunnel()
        return await waitForStatus(of: manager, until: { $0 == .disconnected || $0 == .invalid })
    }

    private static func loadOwnedManager(createIfMissing: Bool) async throws -> NETunnelProviderManager {
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw systemError(error, stage: "loadAllFromPreferences")
        }
        let owned = managers.filter(isOwned)
        guard owned.count <= 1 else { throw LocalDeviceTunnelError.unavailable }
        if let existing = owned.first {
            do {
                try await existing.loadFromPreferences()
            } catch {
                throw systemError(error, stage: "loadFromPreferences")
            }
            guard isOwned(existing) else { throw LocalDeviceTunnelError.unavailable }
            if createIfMissing, let configuration = existing.protocolConfiguration as? NETunnelProviderProtocol,
               !existing.isEnabled || existing.isOnDemandEnabled || !(existing.onDemandRules ?? []).isEmpty || configuration.serverAddress != "10.7.0.1" {
                configuration.serverAddress = "10.7.0.1"
                existing.isEnabled = true
                existing.isOnDemandEnabled = false
                existing.onDemandRules = []
                try await existing.saveToPreferences()
                try await existing.loadFromPreferences()
            }
            manager = existing
            return existing
        }
        guard createIfMissing else { throw LocalDeviceTunnelError.notConfigured }

        let created = NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = "10.7.0.1"
        created.protocolConfiguration = configuration
        created.localizedDescription = profileDescription
        created.isEnabled = true
        created.isOnDemandEnabled = false
        created.onDemandRules = []
        do {
            try await created.saveToPreferences()
            try await created.loadFromPreferences()
        } catch {
            throw systemError(error, stage: "save/load new configuration")
        }
        guard isOwned(created) else { throw LocalDeviceTunnelError.unavailable }
        manager = created
        return created
    }

    private static func isOwned(_ manager: NETunnelProviderManager) -> Bool {
        guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return false
        }
        return configuration.providerBundleIdentifier == providerBundleIdentifier
    }

    private static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        case .invalid, .disconnected:
            return false
        @unknown default:
            return true
        }
    }

    private static func waitForStatus(of manager: NETunnelProviderManager,
                                      until condition: (NEVPNStatus) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + statusTimeout
        var lastStatus: NEVPNStatus?
        while !condition(manager.connection.status) {
            if lastStatus != manager.connection.status {
                lastStatus = manager.connection.status
                DiagnosticLog.event("local.wait status=\(manager.connection.status.rawValue)")
            }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return true
    }

    private nonisolated static func systemError(_ error: Error, stage: String) -> LocalDeviceTunnelError {
        let error = error as NSError
        // Keep system metadata only; userInfo and descriptions may contain peer details.
        let domain = [NEVPNErrorDomain, NEVPNConnectionErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain].contains(error.domain) ? error.domain : "other"
        return .system(stage: stage, domain: domain, code: error.code)
    }

    private static func timeoutError(_ manager: NETunnelProviderManager) async -> LocalDeviceTunnelError {
        let status = manager.connection.status.rawValue
        // Read before cleanup calls stopTunnel, which can replace the original failure.
        let detail: String = await withCheckedContinuation { continuation in
            manager.connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error.map { systemError($0, stage: "disconnect").localizedDescription } ?? "系统未提供断开错误")
            }
        }
        return .connectionTimedOut(status: status, detail: detail)
    }
}

enum LocalDeviceTunnelError: LocalizedError {
    case notConfigured
    case unavailable
    case system(stage: String, domain: String, code: Int)
    case connectionTimedOut(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "本地设备隧道尚未配置."
        case .unavailable:
            return "本地设备隧道配置或会话不可用."
        case let .system(stage, domain, code):
            return "\(stage): \(domain) code=\(code)."
        case let .connectionTimedOut(status, detail):
            return "等待本机 VPN 启动超时, status=\(status). \(detail)"
        }
    }
}
