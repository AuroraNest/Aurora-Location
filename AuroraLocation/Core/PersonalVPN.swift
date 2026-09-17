import Combine
import Darwin
import Foundation
import NetworkExtension
import Security

struct PersonalVPNConfiguration: Equatable {
    var serverAddress: String = ""
    var remoteIdentifier: String = ""
    var username: String = ""

    func validationError() -> PersonalVPNValidationError? {
        guard Self.isBareHostOrIP(serverAddress) else { return .invalidServerAddress }
        guard Self.isBareHostOrIP(remoteIdentifier) else { return .invalidRemoteIdentifier }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missingUsername }
        return nil
    }

    static func isBareHostOrIP(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate == value, !candidate.isEmpty, candidate.count <= 253,
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !candidate.contains("://"), !candidate.contains(where: { "/?#@".contains($0) }) else {
            return false
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, candidate, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, candidate, &ipv6) == 1 { return true }

        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

enum PersonalVPNValidationError: LocalizedError {
    case invalidServerAddress
    case invalidRemoteIdentifier
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: return "请输入不含 URL, 路径或端口的 VPN 服务器地址."
        case .invalidRemoteIdentifier: return "请输入已确认的服务器证书标识."
        case .missingUsername: return "请输入 VPN 用户名."
        }
    }
}

@MainActor
final class PersonalVPN: ObservableObject {
    private static let profileDescription = "Aurora Location Personal VPN"
    private static let keychainService = "com.auroraleelabs.AuroraLocation.personal-vpn"
    private static let keychainAccountPrefix = "ikev2-eap."

    @Published private(set) var status = "未配置"
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var isActive = false
    @Published private(set) var errorMessage: String?
    @Published var configuration = PersonalVPNConfiguration()
    @Published private(set) var hasSavedPassword = false

    var hasConfiguration: Bool { isOwnedProfile }

    private let manager = NEVPNManager.shared()
    private var statusObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateConnectionStatus() }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange, object: manager, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(updateDraft: false) }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    // This is read-only and intentionally does not start a VPN connection.
    func refresh(updateDraft: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await loadPreferences()
            guard isEmptyProfile || isOwnedProfile else { throw PersonalVPNError.unexpectedProfile }
            if let ikev2 = manager.protocolConfiguration as? NEVPNProtocolIKEv2 {
                if updateDraft {
                    configuration = PersonalVPNConfiguration(
                        serverAddress: ikev2.serverAddress ?? "",
                        remoteIdentifier: ikev2.remoteIdentifier ?? "",
                        username: ikev2.username ?? ""
                    )
                }
                hasSavedPassword = ikev2.passwordReference.map(isOwnedPasswordReference) ?? false
            } else {
                hasSavedPassword = false
            }
            updateConnectionStatus()
        } catch {
            report(error, status: "无法读取 Personal VPN 配置")
        }
    }

    func connect(password: String) async {
        guard !isBusy, !isActive else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        var newPasswordReference: Data?
        do {
            try await loadPreferences()
            guard !connectionIsActive(manager.connection.status) else {
                updateConnectionStatus()
                return
            }
            guard isEmptyProfile || isOwnedProfile else { throw PersonalVPNError.unexpectedProfile }
            if let validationError = configuration.validationError() { throw validationError }

            let oldPasswordReference = (manager.protocolConfiguration as? NEVPNProtocolIKEv2)?.passwordReference
            let passwordReference: Data
            if password.isEmpty {
                guard let oldPasswordReference, isOwnedPasswordReference(oldPasswordReference) else {
                    throw PersonalVPNError.passwordRequired
                }
                passwordReference = oldPasswordReference
            } else {
                let reference = try savePassword(password)
                newPasswordReference = reference
                passwordReference = reference
            }

            applyConfiguration(passwordReference: passwordReference)
            try await savePreferences()
            // Reload before start because NEVPNManager rejects stale configurations.
            try await loadPreferences()
            guard isOwnedProfile else { throw PersonalVPNError.unexpectedProfile }
            guard (manager.protocolConfiguration as? NEVPNProtocolIKEv2)?.passwordReference == passwordReference,
                  isOwnedPasswordReference(passwordReference) else {
                throw PersonalVPNError.credentialNotConfirmed
            }
            if let newPasswordReference, let oldPasswordReference,
               newPasswordReference != oldPasswordReference,
               isOwnedPasswordReference(oldPasswordReference) {
                try deletePasswordReference(oldPasswordReference)
            }
            hasSavedPassword = true
            try manager.connection.startVPNTunnel()
            status = "正在连接"
            isActive = true
        } catch {
            // A failed save can still have committed. Delete a new item only after checking persisted state.
            do {
                try await loadPreferences()
                let persistedReference = (manager.protocolConfiguration as? NEVPNProtocolIKEv2)?.passwordReference
                if let newPasswordReference, persistedReference != newPasswordReference {
                    try? deletePasswordReference(newPasswordReference)
                }
                hasSavedPassword = persistedReference.map(isOwnedPasswordReference) ?? false
            } catch {
                // Retain the credential while the system's stored reference is unknown.
            }
            updateConnectionStatus()
            report(error, status: "Personal VPN 未连接")
        }
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await loadPreferences()
            guard isOwnedProfile else { throw PersonalVPNError.unexpectedProfile }
            updateConnectionStatus()
            guard isActive else { return }
            manager.connection.stopVPNTunnel()
            status = "正在断开"
            isActive = true
        } catch {
            report(error, status: "无法断开 Personal VPN")
        }
    }

    func readLastDisconnectError() {
        guard !isBusy, !isActive else { return }
        isBusy = true
        manager.connection.fetchLastDisconnectError { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isBusy = false }
                self.updateConnectionStatus()
                guard !self.isActive else { return }
                self.errorMessage = Self.disconnectDescription(error as NSError?)
            }
        }
    }

    static func disconnectDescription(_ error: NSError?) -> String {
        guard let error else { return "系统未提供最近断开原因." }
        guard error.domain == NEVPNConnectionErrorDomain else {
            return "系统返回了未识别的 VPN 断开错误."
        }
        let reason: String
        switch error.code {
        case 2: reason = "没有可用网络"
        case 3: reason = "网络变化导致连接无法保持"
        case 4, 13: reason = "系统 VPN 配置无效或不存在"
        case 5: reason = "服务器地址解析失败"
        case 6, 7: reason = "服务器未响应或连接失效"
        case 8: reason = "账号认证失败"
        case 9...11: reason = "客户端证书无效或不在有效期内"
        case 12, 14: reason = "系统 VPN 组件不可用"
        case 15: reason = "VPN 协议协商失败"
        case 16: reason = "服务器断开连接"
        case 17...19: reason = "服务器证书无效或不在有效期内"
        default: reason = "VPN 连接已终止"
        }
        // System userInfo may contain peer details; display only the documented error category.
        return "最近断开: \(reason) (VPN \(error.code))."
    }

    func removeConfiguration() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        var removedProfile = false
        do {
            try await loadPreferences()
            guard isOwnedProfile else { throw PersonalVPNError.unexpectedProfile }
            updateConnectionStatus()
            guard !isActive else { throw PersonalVPNError.disconnectFirst }
            let passwordReference = (manager.protocolConfiguration as? NEVPNProtocolIKEv2)?.passwordReference
            try await removePreferences()
            removedProfile = true
            configuration = PersonalVPNConfiguration()
            hasSavedPassword = false
            try await loadPreferences()
            updateConnectionStatus()
            if let passwordReference, isOwnedPasswordReference(passwordReference) {
                try deletePasswordReference(passwordReference)
            }
        } catch {
            report(error, status: removedProfile ? "配置已移除, 后续清理未完成" : "无法移除 Personal VPN 配置")
        }
    }

    private var isEmptyProfile: Bool {
        Self.isUnconfigured(protocolConfiguration: manager.protocolConfiguration,
                            isEnabled: manager.isEnabled, status: manager.connection.status)
    }

    static func isUnconfigured(protocolConfiguration: NEVPNProtocol?, isEnabled: Bool, status: NEVPNStatus) -> Bool {
        // iOS supplies a default description even before this app has saved a VPN configuration.
        protocolConfiguration == nil && !isEnabled && status == .invalid
    }

    private var isOwnedProfile: Bool {
        guard manager.localizedDescription == Self.profileDescription,
              !manager.isOnDemandEnabled,
              (manager.onDemandRules ?? []).isEmpty,
              let ikev2 = manager.protocolConfiguration as? NEVPNProtocolIKEv2,
              let serverAddress = ikev2.serverAddress,
              let remoteIdentifier = ikev2.remoteIdentifier,
              let username = ikev2.username,
              PersonalVPNConfiguration.isBareHostOrIP(serverAddress),
              PersonalVPNConfiguration.isBareHostOrIP(remoteIdentifier),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ikev2.authenticationMethod == .none,
              ikev2.useExtendedAuthentication,
              !ikev2.includeAllNetworks else {
            return false
        }
        return true
    }

    private func applyConfiguration(passwordReference: Data) {
        let ikev2 = NEVPNProtocolIKEv2()
        ikev2.serverAddress = configuration.serverAddress
        ikev2.remoteIdentifier = configuration.remoteIdentifier
        ikev2.username = configuration.username
        ikev2.passwordReference = passwordReference
        ikev2.authenticationMethod = .none
        ikev2.useExtendedAuthentication = true
        ikev2.includeAllNetworks = false
        manager.protocolConfiguration = ikev2
        manager.localizedDescription = Self.profileDescription
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        manager.isEnabled = true
    }

    private func updateConnectionStatus() {
        switch manager.connection.status {
        case .invalid:
            status = isEmptyProfile ? "未配置" : "配置已停用"
            isActive = false
            isConnected = false
        case .disconnected:
            status = isEmptyProfile ? "未配置" : "已断开"
            isActive = false
            isConnected = false
        case .connecting:
            status = "正在连接"
            isActive = true
            isConnected = false
        case .connected:
            status = "已连接"
            isActive = true
            isConnected = true
        case .reasserting:
            status = "正在重连"
            isActive = true
            isConnected = false
        case .disconnecting:
            status = "正在断开"
            isActive = true
            isConnected = false
        @unknown default:
            status = "状态未知"
            isActive = false
            isConnected = false
        }
    }

    private func connectionIsActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        case .invalid, .disconnected: return false
        @unknown default: return true
        }
    }

    private func savePassword(_ password: String) throws -> Data {
        let account = Self.keychainAccountPrefix + UUID().uuidString
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(password.utf8),
            kSecReturnPersistentRef: true
        ]
        var item: CFTypeRef?
        guard SecItemAdd(query as CFDictionary, &item) == errSecSuccess,
              let reference = item as? Data else {
            throw PersonalVPNError.keychainFailure
        }
        return reference
    }

    private func isOwnedPasswordReference(_ reference: Data) -> Bool {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: reference,
            kSecReturnAttributes: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [CFString: Any],
              attributes[kSecAttrService] as? String == Self.keychainService,
              let account = attributes[kSecAttrAccount] as? String else {
            return false
        }
        return account.hasPrefix(Self.keychainAccountPrefix)
    }

    private func deletePasswordReference(_ reference: Data) throws {
        let query: [CFString: Any] = [kSecValuePersistentRef: reference]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw PersonalVPNError.keychainFailure
        }
    }

    private func loadPreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            manager.loadFromPreferences { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: PersonalVPNError.preferencesFailure) }
            }
        }
    }

    private func savePreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            manager.saveToPreferences { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: PersonalVPNError.preferencesFailure) }
            }
        }
    }

    private func removePreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            manager.removeFromPreferences { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: PersonalVPNError.preferencesFailure) }
            }
        }
    }

    private func report(_ error: Error, status: String) {
        updateConnectionStatus()
        if !isActive { self.status = status }
        if let validation = error as? PersonalVPNValidationError {
            errorMessage = validation.errorDescription
        } else if let operation = error as? PersonalVPNError {
            errorMessage = operation.errorDescription
        } else {
            errorMessage = "系统未能完成 VPN 操作. 请检查连接状态后重试."
        }
    }
}

private enum PersonalVPNError: LocalizedError {
    case unexpectedProfile
    case passwordRequired
    case keychainFailure
    case preferencesFailure
    case disconnectFirst
    case credentialNotConfirmed

    var errorDescription: String? {
        switch self {
        case .unexpectedProfile: return "检测到未识别的 VPN 配置, 未做修改."
        case .passwordRequired: return "请输入 VPN 密码, 或保留已保存的密码."
        case .keychainFailure: return "无法安全保存 VPN 凭据."
        case .preferencesFailure: return "系统未能读取或更新 VPN 配置."
        case .disconnectFirst: return "请先断开此 IKEv2, 再移除配置."
        case .credentialNotConfirmed: return "未能确认系统已保存新凭据, 未启动连接."
        }
    }
}
