import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var selected = Coordinate.timesSquare
    @Published var selectedName = "Times Square"
    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []
    @Published var isBusy = false
    @Published var isSimulating = false
    @Published var connectionMode = ConnectionMode.saved {
        didSet {
            UserDefaults.standard.set(connectionMode.rawValue, forKey: ConnectionMode.storageKey)
            auroraVPNReady = false
        }
    }
    @Published private(set) var isOutdoorMode = false
    @Published private(set) var isOutdoorPrepared = false
    @Published private(set) var automaticOutdoorStatus: String?
    @Published private(set) var needsCellularRecovery = UserDefaults.standard.bool(forKey: CellularShortcut.recoveryKey) {
        didSet { UserDefaults.standard.set(needsCellularRecovery, forKey: CellularShortcut.recoveryKey) }
    }
    @Published private(set) var walkingSession: WalkingSession?
    @Published var errorMessage: String?
    @Published var lastOperation = "状态未知"
    @Published var wifiAvailable = false
    @Published var tunnelStatus = "尚未检测"
    @Published var developerStatus = "尚未检测"
    @Published var relayStatus = "尚未运行" {
        didSet { locationMonitor.recordDebugEvent("relay=\(relayStatus)") }
    }
    @Published var showSetup = false
    let pairing = PairingService()
    let locationMonitor = LocationMonitor()
    private var lastErrorCode = "none"
    private var storageLoaded = false
    private var pairingObservation: AnyCancellable?
    private var maintenanceTask: Task<Void, Never>?
    private var cellularRequest: CellularShortcut.Request?
    private var cellularTimeoutTask: Task<Void, Never>?
    private var automaticCoordinate: Coordinate?
    private var automaticFailure: String?
    private var recoveryAttemptedThisLaunch = false
    private var auroraVPNRequest: AuroraVPN.Request?
    private var auroraVPNContinuation: CheckedContinuation<VPNWaitResult, Never>?
    private var auroraVPNTimeoutTask: Task<Void, Never>?
    private var auroraVPNReady = false

    private enum VPNWaitResult {
        case callback(AuroraVPN.Result), openFailed, timedOut, cancelled
    }

    init() {
        loadPlaces()
        refresh()
        showSetup = !pairing.hasPairing
        pairingObservation = pairing.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func refresh() {
        locationMonitor.recordDebugEvent("refresh")
        wifiAvailable = NetworkStatus.hasWiFiAddress
        pairing.refresh()
        if !isSimulating {
            tunnelStatus = "尚未检测"
            developerStatus = "尚未检测"
        }
        if !storageLoaded { loadPlaces() }
    }

    func enteredBackground() {
        locationMonitor.recordDebugEvent("background simulating=\(isSimulating)")
        guard isSimulating else { return }
        developerStatus = "会话已保留, 后台持续状态未知"
        relayStatus = connectionMode == .auroraVPN ? "Aurora VPN 由外部 App 保持, 当前状态待核验" : "中继未主动关闭, 系统可能暂停运行"
    }

    func select(_ coordinate: Coordinate, name: String? = nil) {
        guard coordinate.isValid else { report(.invalidCoordinate); return }
        selected = coordinate
        selectedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? coordinate.label
    }

    func execute(_ command: LocationCommand) async {
        if case .set = command, isWalkingSessionActive {
            errorMessage = "请先在模拟步行页面结束当前路线, 再设置固定位置."
            return
        }
        if case .set = command, !isSimulating, !isBusy, !pairing.isBusy { isOutdoorMode = false }
        await runCommand(command)
    }

    var canCancelAutomaticOutdoor: Bool {
        (cellularRequest != nil && cellularRequest?.phase != .restore) ||
            (automaticCoordinate != nil && auroraVPNRequest != nil)
    }

    var canCancelAuroraVPN: Bool { auroraVPNRequest != nil && automaticCoordinate == nil }

    func startAutomaticOutdoor() async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        if isSimulating { await executeOutdoor(); return }
        if needsCellularRecovery { await recoverCellular(); return }
        pairing.refresh()
        guard pairing.hasPairing else { showSetup = true; report(.pairingMissing); return }
        guard selected.isValid else { report(.invalidCoordinate); return }
        automaticCoordinate = selected
        automaticFailure = nil
        errorMessage = nil
        await requestCellular(.prepare)
    }

    func resumeCellularRecovery() async {
        guard needsCellularRecovery, !recoveryAttemptedThisLaunch,
              !isBusy, !pairing.isBusy else { return }
        recoveryAttemptedThisLaunch = true
        await recoverCellular()
    }

    func recoverCellular() async {
        guard !isBusy, !pairing.isBusy else { return }
        automaticFailure = "上次自动流程未完成. 恢复蜂窝后, 请确认当前位置再重试."
        await requestCellular(.restore)
    }

    func cancelAutomaticOutdoor() async {
        if let request = cellularRequest, request.phase != .restore {
            await failAutomaticOutdoor(request.phase, message: "自动修改已取消.")
        } else if automaticCoordinate != nil, auroraVPNRequest != nil {
            completeAuroraVPN(.cancelled)
        }
    }

    func cancelAuroraVPNConnection() { completeAuroraVPN(.cancelled) }

    private func requestCellular(_ phase: CellularShortcut.Phase) async {
        let request = CellularShortcut.Request(phase: phase)
        cellularRequest = request
        isBusy = true
        if phase == .offline {
            // Persist before leaving the app; after a process restart, recover networking, never replay set.
            needsCellularRecovery = true
        }
        switch phase {
        case .prepare: automaticOutdoorStatus = "正在准备网络"
        case .offline: automaticOutdoorStatus = "正在切换本机连接"
        case .restore: automaticOutdoorStatus = "正在恢复蜂窝"
        }
        DiagnosticLog.event("automatic.request phase=\(phase.rawValue)")
        cellularTimeoutTask?.cancel()
        cellularTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) }
            catch { return }
            guard let self, self.cellularRequest?.token == request.token else { return }
            self.cellularTimeoutTask = nil
            await self.failAutomaticOutdoor(phase, message: "等待系统快捷指令超时.")
        }
        let opened = await UIApplication.shared.open(request.url)
        if !opened, cellularRequest?.token == request.token {
            await failAutomaticOutdoor(phase, message: "无法打开快捷指令. 请先安装 \(CellularShortcut.name).")
        }
    }

    private func handleCellularCallback(_ url: URL) async {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = parts?.queryItems ?? []
        let knownKeys: Set<String> = ["token", "phase", "outcome", "result", "errorCode", "errorDomain", "errorMessage"]
        let keys = items.map { knownKeys.contains($0.name) ? $0.name : "unknown" }.sorted().joined(separator: ",")
        let code = items.first { $0.name == "errorCode" }?.value.flatMap(Int.init)
        DiagnosticLog.event("automatic.callback fields=\(keys) rootPath=\(parts?.path == "/") pending=\(cellularRequest != nil) code=\(code.map(String.init) ?? "none")")
        guard var request = cellularRequest, let outcome = request.consume(url) else {
            DiagnosticLog.event("automatic.callback ignored")
            return
        }
        cellularRequest = nil
        cellularTimeoutTask?.cancel()
        DiagnosticLog.event("automatic.callback phase=\(request.phase.rawValue) outcome=\(outcome.rawValue)")
        guard outcome == .success else {
            let suffix = code.map { " 系统错误码: \($0)." } ?? ""
            await failAutomaticOutdoor(request.phase, message: "系统快捷指令未完成. 请确认 \(CellularShortcut.name)已安装并允许运行." + suffix)
            return
        }
        switch request.phase {
        case .prepare:
            UserDefaults.standard.set(true, forKey: CellularShortcut.installedKey)
            // The radio action can finish before the interface address disappears.
            for _ in 0..<30 where NetworkStatus.hasWiFiAddress {
                try? await Task.sleep(for: .milliseconds(100))
            }
            isBusy = false
            await prepareOutdoor()
            guard automaticCoordinate != nil else { return }
            guard isOutdoorPrepared else {
                await failAutomaticOutdoor(.prepare, message: errorMessage ?? "连接未能准备.")
                return
            }
            await requestCellular(.offline)
        case .offline:
            guard let coordinate = automaticCoordinate, isOutdoorPrepared,
                  (connectionMode == .auroraVPN ? auroraVPNReady : LocalDeviceTunnel.isConnected),
                  !NetworkStatus.hasWiFiAddress else {
                await failAutomaticOutdoor(.offline, message: "连接未保持就绪, 尚未发送定位指令.")
                return
            }
            automaticOutdoorStatus = "正在修改定位"
            isBusy = false
            await runCommand(.set(coordinate), outdoor: true)
            automaticFailure = errorMessage
            errorMessage = nil
            await requestCellular(.restore)
        case .restore:
            needsCellularRecovery = false
            finishAutomaticOutdoor(message: automaticFailure)
        }
    }

    private func failAutomaticOutdoor(_ phase: CellularShortcut.Phase, message: String) async {
        cellularRequest = nil
        cellularTimeoutTask?.cancel()
        if phase == .restore {
            recoveryAttemptedThisLaunch = true
            finishAutomaticOutdoor(message: message + " 蜂窝尚未确认恢复, 请点恢复蜂窝或在控制中心开启.")
            return
        }
        automaticFailure = message
        errorMessage = nil
        if isOutdoorPrepared, !isSimulating { await stopTransport() }
        if needsCellularRecovery {
            await requestCellular(.restore)
        } else {
            finishAutomaticOutdoor(message: message)
        }
    }

    private func finishAutomaticOutdoor(message: String?) {
        cellularRequest = nil
        cellularTimeoutTask?.cancel()
        automaticCoordinate = nil
        automaticFailure = nil
        automaticOutdoorStatus = nil
        isBusy = false
        errorMessage = message
    }

    func prepareOutdoor() async {
        guard !isBusy, !pairing.isBusy, !isSimulating else { report(.busy); return }
        guard !NetworkStatus.hasWiFiAddress else { report(.outdoorNetworkActive); return }
        pairing.refresh()
        guard pairing.hasPairing else { showSetup = true; report(.pairingMissing); return }
        isBusy = true
        isOutdoorMode = true
        errorMessage = nil
        DiagnosticLog.begin("outdoor-prepare")
        defer { isBusy = false }
        if connectionMode == .auroraVPN {
            do {
                try await connectAuroraVPN()
                isOutdoorPrepared = true
                tunnelStatus = "Aurora VPN 已报告就绪"
                developerStatus = "请关闭蜂窝后继续, 尚未发送定位指令"
                relayStatus = "Aurora VPN 连接由外部 App 保持"
                lastErrorCode = "none"
            } catch {
                isOutdoorPrepared = false
                report(error as? AuroraLocationError ?? .auroraVPNFailed)
            }
            return
        }
        _ = await ShadowrocketTunnel.stop()
        do {
            try await LocalDeviceTunnel.start()
            // Keep the tunnel alive while the user disables cellular; no developer request yet.
            isOutdoorPrepared = true
            tunnelStatus = "本机 VPN 已连接"
            developerStatus = "请关闭蜂窝后继续, 尚未发送定位指令"
            relayStatus = "AL 本机通道已准备"
            lastErrorCode = "none"
            DiagnosticLog.event("outdoor.prepared")
        } catch {
            report(.localTunnelFailed)
            await stopTransport()
        }
    }

    func cancelOutdoorPreparation() async {
        guard !isBusy, !pairing.isBusy, !isSimulating, isOutdoorPrepared else { return }
        isBusy = true
        isOutdoorMode = true
        defer { isBusy = false }
        await stopTransport()
        if !isOutdoorPrepared {
            isOutdoorMode = false
            tunnelStatus = "尚未检测"
            developerStatus = "尚未检测"
        }
    }

    func executeOutdoor() async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        guard !isWalkingSessionActive, !isSimulating || isOutdoorMode else {
            errorMessage = "请先恢复真实定位, 再切换到蜂窝修改."
            return
        }
        // An interface address is a conservative warning, not proof of the radio switch state.
        guard isSimulating || !NetworkStatus.hasWiFiAddress else {
            report(.outdoorNetworkActive)
            return
        }
        await runCommand(.set(selected), outdoor: true)
    }

    var isWalkingSessionActive: Bool {
        isSimulating && walkingSession != nil && walkingSession?.phase != .interrupted
    }

    func startWalking(route: WalkingRoute, speedKmh: Double) async {
        guard !isWalkingSessionActive else { report(.busy); return }
        guard let session = WalkingSession(route: route, speedKmh: speedKmh,
                                           startedAt: ProcessInfo.processInfo.systemUptime) else {
            errorMessage = "步行速度须在 1...8 km/h 之间, 路线须包含有效的起点和终点."
            return
        }
        if !isSimulating, !isBusy, !pairing.isBusy { isOutdoorMode = false }
        await runCommand(.set(session.coordinate), startingWalk: session)
    }

    func pauseWalking() {
        guard !isBusy, isWalkingSessionActive, walkingSession?.phase == .walking else { return }
        walkingSession?.pause()
        lastOperation = "步行已暂停, 保持当前位置"
        DiagnosticLog.event("walking.paused")
    }

    func resumeWalking() {
        guard !isBusy, !pairing.isBusy, isWalkingSessionActive, walkingSession?.phase == .paused else { return }
        walkingSession?.resume(at: ProcessInfo.processInfo.systemUptime)
        lastOperation = "模拟步行中"
        DiagnosticLog.event("walking.resumed")
    }

    private func runCommand(_ command: LocationCommand, startingWalk: WalkingSession? = nil, outdoor: Bool = false) async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        if case .set(let coordinate) = command, !coordinate.isValid {
            report(.invalidCoordinate)
            return
        }
        isBusy = true
        isOutdoorPrepared = false
        if outdoor { isOutdoorMode = true }
        stopMaintenance()
        if case .clear = command { DiagnosticLog.begin("clear") }
        else { DiagnosticLog.begin(startingWalk == nil ? "set" : "walking-start") }
        DiagnosticLog.event("network wifiAddress=\(NetworkStatus.hasWiFiAddress) interfaces=\(NetworkStatus.interfaceSummary)")
        errorMessage = nil
        var engineAttempted = false
        do {
            try await prepareConnection()
            let path = try PairingStore.fileURL().path
            engineAttempted = true
            try await LocationEngine.perform(command, pairingPath: path)
            if DiagnosticLog.enabled {
                let snapshot = await transportSnapshot()
                DiagnosticLog.event("native.ok relay=\(snapshot)")
            }
            lastErrorCode = "none"
            switch command {
            case .set(let coordinate):
                isSimulating = true
                // Connection setup can take seconds; walking starts only after the first set succeeds.
                walkingSession = startingWalk.flatMap {
                    WalkingSession(route: $0.route, speedKmh: $0.speedKmh,
                                   startedAt: ProcessInfo.processInfo.systemUptime)
                }
                locationMonitor.setTarget(coordinate)
                startMaintenance(coordinate, pairingPath: path)
                developerStatus = "指令已完成, 会话已保留"
                relayStatus = connectionMode == .auroraVPN ? "Aurora VPN 连接由外部 App 保持" : "中继运行中, 支持当前定位会话"
                let name = selected == coordinate ? selectedName : coordinate.label
                select(coordinate, name: name)
                lastOperation = startingWalk == nil ? "最近操作: 已发送模拟定位指令" : "模拟步行中"
                if isOutdoorMode {
                    lastOperation = "户外定位指令已发送, 确认位置后可恢复蜂窝"
                    relayStatus = connectionMode == .auroraVPN ? "Aurora VPN 连接由外部 App 保持" : "AL 本机通道运行中"
                }
                var snapshot = PlacesSnapshot(favorites: favorites, recents: recents)
                snapshot.record(SavedPlace(name: name, coordinate: coordinate))
                savePlaces(snapshot)
            case .clear:
                isSimulating = false
                walkingSession = nil
                locationMonitor.stop()
                developerStatus = "恢复指令已完成, 会话已关闭"
                lastOperation = "最近操作: 已发送恢复真实定位指令"
            }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        } catch {
            if DiagnosticLog.enabled {
                let snapshot = await transportSnapshot()
                DiagnosticLog.event("operation.failed relay=\(snapshot)")
            }
            isSimulating = false
            if let startingWalk { walkingSession = startingWalk }
            walkingSession?.interrupt()
            locationMonitor.stop()
            await LocationEngine.disconnect()
            lastOperation = "状态未知"
            developerStatus = "连接或指令未完成"
            if engineAttempted { developerStatus += " / " + (await LocationEngine.lastFailureDetails()) }
            report(error as? AuroraLocationError ?? .pairingInvalid)
        }
        if !isSimulating {
            await stopTransport()
            if case .clear = command, errorMessage == nil { isOutdoorMode = false }
        }
        DiagnosticLog.event("end simulating=\(isSimulating)")
        isBusy = false
    }

    func checkConnection() async {
        await checkConnection(precheck: true)
    }

    private func checkConnection(precheck: Bool) async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        guard !isSimulating else {
            developerStatus = "定位会话已保留, 恢复真实定位后可重新检测"
            return
        }
        isBusy = true
        isOutdoorMode = false
        DiagnosticLog.begin(precheck ? "check" : "check-native")
        DiagnosticLog.event("network wifiAddress=\(NetworkStatus.hasWiFiAddress) interfaces=\(NetworkStatus.interfaceSummary)")
        errorMessage = nil
        var engineAttempted = false
        do {
            try await prepareConnection(precheck: precheck)
            engineAttempted = true
            try await LocationEngine.perform(nil, pairingPath: PairingStore.fileURL().path)
            if DiagnosticLog.enabled {
                let snapshot = await transportSnapshot()
                DiagnosticLog.event("native.ok relay=\(snapshot)")
            }
            developerStatus = "检测成功, 会话已关闭"
            lastErrorCode = "none"
        } catch {
            if DiagnosticLog.enabled {
                let snapshot = await transportSnapshot()
                DiagnosticLog.event("native.failure relay=\(snapshot)")
            }
            developerStatus = "检测未完成"
            if engineAttempted { developerStatus += " / " + (await LocationEngine.lastFailureDetails()) }
            report(error as? AuroraLocationError ?? .pairingInvalid)
        }
        await stopTransport()
        DiagnosticLog.event("end check")
        isBusy = false
    }

    private func prepareConnection(precheck: Bool = true) async throws {
        wifiAvailable = NetworkStatus.hasWiFiAddress
        pairing.refresh()
        guard pairing.hasPairing else { showSetup = true; throw AuroraLocationError.pairingMissing }
        if connectionMode == .auroraVPN {
            if !isSimulating { try await connectAuroraVPN() }
            relayStatus = "Aurora VPN 连接由外部 App 保持"
        } else if isOutdoorMode {
            if isSimulating {
                guard LocalDeviceTunnel.isConnected else { throw AuroraLocationError.tunnelUnavailable }
            } else {
                guard !NetworkStatus.hasWiFiAddress else { throw AuroraLocationError.outdoorNetworkActive }
                _ = await ShadowrocketTunnel.stop()
                do { try await LocalDeviceTunnel.start() }
                catch { throw AuroraLocationError.localTunnelFailed }
            }
            relayStatus = "AL 本机通道已启动"
        } else {
            if !isSimulating {
                guard await LocalDeviceTunnel.stop() else { throw AuroraLocationError.localTunnelStopFailed }
                isOutdoorPrepared = false
            }
            try await ShadowrocketTunnel.start()
            relayStatus = "本机中继已启动"
        }
        if isSimulating {
            developerStatus = "正在发送指令"
            return
        }
        // The diagnostic entry isolates one real native stream from the extra TCP probe.
        if !precheck {
            tunnelStatus = "仅运行真实开发者握手"
            developerStatus = "正在连接"
            DiagnosticLog.event("precheck.skipped diagnostic-only")
            if DiagnosticLog.enabled {
                let snapshot = await transportSnapshot()
                DiagnosticLog.event("native.begin relay=\(snapshot)")
            }
            return
        }
        tunnelStatus = "正在检测"
        if DiagnosticLog.enabled {
            let snapshot = await transportSnapshot()
            DiagnosticLog.event("precheck.begin relay=\(snapshot)")
        }
        let probe = await NetworkStatus.probeTunnel()
        if DiagnosticLog.enabled {
            let snapshot = await transportSnapshot()
            DiagnosticLog.event("precheck.end \(probe.details) relay=\(snapshot)")
        }
        tunnelStatus = (probe.reachable ? "本机端口可达" : "本机端口不可达") + " / " + probe.details
        guard probe.reachable else { throw AuroraLocationError.tunnelUnavailable }
        developerStatus = "正在连接"
        if DiagnosticLog.enabled {
            let snapshot = await transportSnapshot()
            DiagnosticLog.event("native.begin relay=\(snapshot)")
        }
    }

    private func transportSnapshot() async -> String {
        if connectionMode == .auroraVPN { return "aurora-vpn ready=\(auroraVPNReady)" }
        if isOutdoorMode { return "local connected=\(LocalDeviceTunnel.isConnected)" }
        return await ShadowrocketTunnel.snapshot()
    }

    private func stopTransport() async {
        if connectionMode == .auroraVPN {
            isOutdoorPrepared = false
            // The external App owns the VPN; require fresh readiness for the next session.
            auroraVPNReady = false
            relayStatus = "Aurora VPN 连接由外部 App 保持"
            return
        }
        relayStatus = await ShadowrocketTunnel.stop()
        if isOutdoorMode {
            if await LocalDeviceTunnel.stop() {
                isOutdoorPrepared = false
                relayStatus = "AL 本机通道已关闭"
            }
            else {
                relayStatus = "AL 本机通道尚未确认关闭"
                errorMessage = AuroraLocationError.localTunnelStopFailed.localizedDescription
            }
        }
    }

    private func connectAuroraVPN() async throws {
        if auroraVPNReady { return }
        let request = AuroraVPN.Request()
        auroraVPNRequest = request
        tunnelStatus = "等待 Aurora VPN 连接"
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<VPNWaitResult, Never>) in
            auroraVPNContinuation = continuation
            auroraVPNTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) }
                catch { return }
                guard let self, self.auroraVPNRequest?.id == request.id else { return }
                self.completeAuroraVPN(.timedOut)
            }
            Task { [weak self] in
                let opened = await UIApplication.shared.open(request.url)
                guard let self, !opened, self.auroraVPNRequest?.id == request.id else { return }
                self.completeAuroraVPN(.openFailed)
            }
        }
        switch result {
        case .callback(.ready):
            auroraVPNReady = true
            tunnelStatus = "Aurora VPN 已报告就绪, 正在核验开发者连接"
        case .callback(.cancel), .cancelled: throw AuroraLocationError.auroraVPNCancelled
        case .callback(.error): throw AuroraLocationError.auroraVPNFailed
        case .openFailed: throw AuroraLocationError.auroraVPNOpenFailed
        case .timedOut: throw AuroraLocationError.auroraVPNTimeout
        }
    }

    private func completeAuroraVPN(_ result: VPNWaitResult) {
        guard let continuation = auroraVPNContinuation else { return }
        auroraVPNRequest = nil
        auroraVPNContinuation = nil
        auroraVPNTimeoutTask?.cancel()
        auroraVPNTimeoutTask = nil
        continuation.resume(returning: result)
    }

    private func handleAuroraVPNCallback(_ url: URL) {
        guard var request = auroraVPNRequest, let result = request.consume(url) else {
            DiagnosticLog.event("aurora-vpn.callback ignored")
            return
        }
        DiagnosticLog.event("aurora-vpn.callback result=\(result.rawValue)")
        completeAuroraVPN(.callback(result))
    }

    private func startMaintenance(_ coordinate: Coordinate, pairingPath: String) {
        // One writer drives both modes. Map selection never changes an already applied session.
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.walkingSession?.phase == .walking ? 1 : 4
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard !Task.isCancelled,
                      await self?.maintainSession(coordinate, pairingPath: pairingPath) == true else { return }
            }
        }
    }

    private func stopMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        locationMonitor.recordDebugEvent("maintenanceStopped")
    }

    private func maintainSession(_ coordinate: Coordinate, pairingPath: String) async -> Bool {
        guard isSimulating else { return false }
        guard !isBusy, !pairing.isBusy else { return true }
        isBusy = true
        defer { isBusy = false }
        var nextStep = walkingSession
        nextStep?.advance(to: ProcessInfo.processInfo.systemUptime)
        if nextStep?.phase == .interrupted {
            walkingSession = nextStep
            stopMaintenance()
            isSimulating = false
            locationMonitor.stop()
            await LocationEngine.disconnect()
            await stopTransport()
            lastOperation = "步行更新中断, 状态未知"
            developerStatus = "更新间隔过长, 会话已关闭"
            errorMessage = "步行更新被暂停过久, 已停止路线以避免位置突然跳跃. 请保持 App 前台, 或开启后台位置监测后重新开始."
            DiagnosticLog.event("walking.interrupted update-gap")
            return false
        }
        do {
            if isOutdoorMode, connectionMode == .existing, !LocalDeviceTunnel.isConnected {
                throw AuroraLocationError.tunnelUnavailable
            }
            let appliedCoordinate = nextStep?.coordinate ?? coordinate
            try await LocationEngine.perform(.set(appliedCoordinate), pairingPath: pairingPath)
            if let nextStep {
                let didArrive = walkingSession?.phase == .walking && nextStep.phase == .arrived
                // Publish progress only after the device accepts the new coordinate.
                walkingSession = nextStep
                locationMonitor.moveTarget(to: appliedCoordinate)
                if didArrive {
                    lastOperation = "已到达终点, 持续保持定位"
                    DiagnosticLog.event("walking.arrived")
                }
            }
            locationMonitor.recordDebugEvent("maintenanceSet")
            return true
        } catch {
            // ponytail: stop on disconnect; add bounded reconnect after handshake recovery is validated.
            stopMaintenance()
            isSimulating = false
            walkingSession?.interrupt()
            locationMonitor.stop()
            lastOperation = "定位保持中断, 状态未知"
            developerStatus = "保持指令未完成 / " + (await LocationEngine.lastFailureDetails())
            report(error as? AuroraLocationError ?? .locationSimulationFailed)
            await stopTransport()
            return false
        }
    }

    func addFavorite(name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = PlacesSnapshot(favorites: favorites, recents: recents)
        if let index = snapshot.favorites.firstIndex(where: { $0.coordinate == selected }) {
            snapshot.favorites[index].name = title.isEmpty ? selectedName : title
        } else {
            snapshot.favorites.insert(SavedPlace(name: title.isEmpty ? selectedName : title, coordinate: selected), at: 0)
        }
        savePlaces(snapshot)
    }

    func removeFavorite(id: UUID) {
        savePlaces(PlacesSnapshot(favorites: favorites.filter { $0.id != id }, recents: recents))
    }

    func removeRecent(id: UUID) {
        savePlaces(PlacesSnapshot(favorites: favorites, recents: recents.filter { $0.id != id }))
    }

    var diagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return """
        Aurora Location \(version)
        iOS: \(UIDevice.current.systemVersion)
        pairingPresent: \(pairing.hasPairing)
        wifiInterfaceAddress: \(wifiAvailable)
        outdoorMode: \(isOutdoorMode)
        tunnel: \(tunnelStatus)
        developerService: \(developerStatus)
        relay: \(relayStatus)
        errorCode: \(lastErrorCode)
        Detailed trace (bounded to 500 events):
        \(DiagnosticLog.report())
        """
    }

    func handleURL(_ url: URL) {
        if url.scheme == AuroraVPN.callbackScheme {
            handleAuroraVPNCallback(url)
            return
        }
        if url.scheme == CellularShortcut.scheme {
            Task { await handleCellularCallback(url) }
            return
        }
        guard automaticOutdoorStatus == nil else { return }
        #if DEBUG
        if url.scheme == "auroralocation", ["check-native", "probe-proxy", "probe-loopback", "probe-loopback-restricted", "probe-peer-loopback"].contains(url.host), url.path.isEmpty,
           url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil {
            guard connectionMode == .existing else { return }
            Task {
                guard !isBusy, !pairing.isBusy, !isSimulating else { return }
                if url.host == "check-native" {
                    await checkConnection(precheck: false)
                    return
                }
                isBusy = true
                defer { isBusy = false }
                let peer = url.host == "probe-peer-loopback"
                let restricted = url.host == "probe-loopback-restricted"
                let loopback = url.host == "probe-loopback" || restricted || peer
                DiagnosticLog.begin(peer ? "peer-loopback-probe" : restricted ? "restricted-loopback-probe" : loopback ? "loopback-probe" : "proxy-probe")
                do {
                    try await ShadowrocketTunnel.start()
                    relayStatus = "代理诊断中继已启动"
                    let probe = loopback ? await NetworkStatus.probeLoopback(restrictListener: restricted, peerToPeer: peer) : await NetworkStatus.probeTunnel(viaLocalProxy: true)
                    if DiagnosticLog.enabled {
                        let snapshot = await ShadowrocketTunnel.snapshot()
                        DiagnosticLog.event("proxy.end wifiAddress=\(NetworkStatus.hasWiFiAddress) \(probe.details) relay=\(snapshot)")
                    }
                    locationMonitor.recordDebugEvent("proxyProbe wifi=\(NetworkStatus.hasWiFiAddress) \(probe.details)")
                } catch {
                    locationMonitor.recordDebugEvent("proxyProbe relay-start-failed")
                }
                relayStatus = await ShadowrocketTunnel.stop()
            }
            return
        }
        #endif
        do {
            let command = try LocationCommand(url: url)
            Task { await execute(command) }
        } catch { report(error as? AuroraLocationError ?? .invalidURL) }
    }

    private func loadPlaces() {
        do {
            let snapshot = try PlacesStore.load()
            favorites = snapshot.favorites
            recents = snapshot.recents
            storageLoaded = true
        } catch { report(.storageFailed) }
    }

    private func savePlaces(_ snapshot: PlacesSnapshot) {
        // A failed read must not turn an empty fallback into a destructive overwrite.
        guard storageLoaded else { report(.storageFailed); return }
        do {
            try PlacesStore.save(snapshot)
            favorites = snapshot.favorites
            recents = snapshot.recents
        } catch { report(.storageFailed) }
    }

    private func report(_ error: AuroraLocationError) {
        DiagnosticLog.event("error=\(error.rawValue) detail=\(developerStatus)")
        locationMonitor.recordDebugEvent("error=\(error.rawValue) wifi=\(NetworkStatus.hasWiFiAddress) probe=\(tunnelStatus) detail=\(developerStatus)")
        lastErrorCode = error.rawValue
        errorMessage = error.localizedDescription
        if error == .localTunnelFailed, !LocalDeviceTunnel.lastFailureDetails.isEmpty {
            errorMessage = error.localizedDescription + " " + LocalDeviceTunnel.lastFailureDetails
        }
        if connectionMode == .auroraVPN, error == .tunnelUnavailable {
            errorMessage = "Aurora VPN 已报告就绪, 但 10.7.0.1 开发者端口不可达. 请检查 VPN 连接后重试."
        }
        if connectionMode == .auroraVPN, error == .clearSimulationFailed {
            errorMessage = "恢复指令未完成. 系统定位状态未知, 请检查 Aurora VPN 连接后重试."
        }
        if connectionMode == .existing, isOutdoorMode,
           [.tunnelUnavailable, .tunnelStartFailed, .clearSimulationFailed].contains(error) {
            errorMessage = "户外连接或定位指令未完成, 系统定位状态未知. 请按蜂窝修改的分步提示重试, 或恢复真实定位."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
