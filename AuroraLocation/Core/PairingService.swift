// Derived in part from Locus, Copyright (c) 2026 Locus contributors, MIT.
import Foundation
import UIKit
import UserNotifications
import idevice

@MainActor
final class PairingService: ObservableObject {
    @Published private(set) var status = "尚未配对"
    @Published private(set) var pin: String?
    @Published private(set) var isBusy = false
    @Published private(set) var hasPairing = false
    private let advertiser = PairableHostAdvertiser()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var cancelled = false

    init() { refresh() }

    func refresh() {
        hasPairing = PairingStore.exists()
        if !isBusy, hasPairing { status = "已保存配对凭据" }
    }

    func start() {
        guard !isBusy else { return }
        guard #available(iOS 27.0, *) else {
            status = "本机配对需要 iOS 27 或更高版本."
            return
        }
        guard NetworkStatus.hasWiFiAddress else {
            status = AuroraLocationError.wifiRequired.localizedDescription
            return
        }
        do { _ = try PairingStore.fileURL() } catch {
            status = AuroraLocationError.pairingSaveFailed.localizedDescription
            return
        }
        isBusy = true
        cancelled = false
        pin = nil
        status = "正在启动本机配对"
        aurora_pairable_host_set_cancelled(false)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Aurora Location pairing") { [weak self] in
            self?.cancel()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let box = PairCallbacks(owner: self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.accept(box)
            DispatchQueue.main.async { box.owner?.finished(result) }
        }
    }

    func cancel() {
        guard isBusy else { return }
        cancelled = true
        status = "正在取消配对"
        aurora_pairable_host_set_cancelled(true)
        teardown()
        // isBusy remains true until Rust has dropped the listener and callback context.
    }

    fileprivate func listening(port: UInt16, identifier: String, name: String, model: String,
                                authTag: String, version: String, minimumVersion: String) {
        guard isBusy, !cancelled else { return }
        advertiser.publish(port: port, identifier: identifier, name: name, model: model,
            authTag: authTag, version: version, minimumVersion: minimumVersion) { [weak self] in
                guard let self else { return }
                self.cancel()
                self.status = "本地网络广播失败. 请允许本地网络访问后重新配对."
            }
        status = "请在系统设置的 Pair with Host 中选择 Aurora Location"
    }

    fileprivate func connected() {
        guard isBusy, !cancelled else { return }
        status = "设备已连接, 请先输入设备锁屏密码"
    }

    fileprivate func showPIN(_ value: String) {
        guard isBusy, !cancelled, value.count == 6, value.allSatisfy(\.isNumber) else { return }
        pin = value
        status = "请在系统设置的验证码提示中输入此 6 位代码"
        let content = UNMutableNotificationContent()
        content.title = "Aurora Location 配对验证码"
        content.body = value
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "aurora.pairing.pin", content: content, trigger: nil))
    }

    private func finished(_ result: Result<Data, AuroraLocationError>) {
        defer { isBusy = false; teardown() }
        guard !cancelled else {
            status = AuroraLocationError.pairingCancelled.localizedDescription
            return
        }
        switch result {
        case .success(let data):
            do {
                try PairingStore.save(data)
                hasPairing = true
                status = "配对已完成并安全保存. 请保持 Shadowrocket 连接后检测连接."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { status = AuroraLocationError.pairingSaveFailed.localizedDescription }
        case .failure(let error): status = error.localizedDescription
        }
    }

    private func teardown() {
        pin = nil
        advertiser.stop()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["aurora.pairing.pin"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["aurora.pairing.pin"])
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private nonisolated static func accept(_ box: PairCallbacks) -> Result<Data, AuroraLocationError> {
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<PairCallbacks>.fromOpaque(context).release() }
        var file: OpaquePointer?
        let error = aurora_pairable_host_accept("Aurora Location", "Mac17,7",
            pairingPIN, context, pairingListening, context, pairingConnected, context, &file)
        defer { if let file { rp_pairing_file_free(file) } }
        if let error {
            idevice_error_free(error)
            return .failure(.pairingFailed)
        }
        guard let file else { return .failure(.pairingFailed) }
        do { return .success(try PairingStore.serialize(file)) }
        catch { return .failure(.pairingSaveFailed) }
    }
}

// Owner is read only on the main queue. The worker retains this box until all C callbacks finish.
private final class PairCallbacks: @unchecked Sendable {
    weak var owner: PairingService?
    init(owner: PairingService) { self.owner = owner }
}

private func pairingPIN(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let box = Unmanaged<PairCallbacks>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.showPIN(value) }
}

private func pairingConnected(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<PairCallbacks>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.connected() }
}

private func pairingListening(_ port: UInt16, _ identifier: UnsafePointer<CChar>?,
    _ name: UnsafePointer<CChar>?, _ model: UnsafePointer<CChar>?, _ authTag: UnsafePointer<CChar>?,
    _ version: UnsafePointer<CChar>?, _ minimumVersion: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context, let identifier, let name, let model, let authTag, let version, let minimumVersion else { return }
    let box = Unmanaged<PairCallbacks>.fromOpaque(context).takeUnretainedValue()
    let values = (String(cString: identifier), String(cString: name), String(cString: model),
        String(cString: authTag), String(cString: version), String(cString: minimumVersion))
    DispatchQueue.main.async {
        box.owner?.listening(port: port, identifier: values.0, name: values.1, model: values.2,
            authTag: values.3, version: values.4, minimumVersion: values.5)
    }
}
