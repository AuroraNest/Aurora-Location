import SwiftUI
import UIKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var selected = Coordinate.timesSquare
    @Published var selectedName = "Times Square"
    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []
    @Published var isBusy = false
    @Published var isSimulating = false
    @Published var errorMessage: String?
    @Published var lastOperation = "状态未知"
    @Published var wifiAvailable = false
    @Published var tunnelStatus = "尚未检测"
    @Published var developerStatus = "尚未检测"
    @Published var relayStatus = "尚未运行"
    @Published var showSetup = false
    let pairing = PairingService()
    let locationMonitor = LocationMonitor()
    private var lastErrorCode = "none"
    private var storageLoaded = false
    private var pairingObservation: AnyCancellable?
    private var maintenanceTask: Task<Void, Never>?

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
        relayStatus = "中继未主动关闭, 系统可能暂停运行"
    }

    func select(_ coordinate: Coordinate, name: String? = nil) {
        guard coordinate.isValid else { report(.invalidCoordinate); return }
        selected = coordinate
        selectedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? coordinate.label
    }

    func execute(_ command: LocationCommand) async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        if case .set(let coordinate) = command, !coordinate.isValid {
            report(.invalidCoordinate)
            return
        }
        isBusy = true
        stopMaintenance()
        errorMessage = nil
        var engineAttempted = false
        do {
            try await prepareConnection()
            let path = try PairingStore.fileURL().path
            engineAttempted = true
            try await LocationEngine.perform(command, pairingPath: path)
            lastErrorCode = "none"
            switch command {
            case .set(let coordinate):
                isSimulating = true
                locationMonitor.setTarget(coordinate)
                startMaintenance(coordinate, pairingPath: path)
                developerStatus = "指令已完成, 会话已保留"
                relayStatus = "中继运行中, 支持当前定位会话"
                let name = selected == coordinate ? selectedName : coordinate.label
                select(coordinate, name: name)
                lastOperation = "最近操作: 已发送模拟定位指令"
                var snapshot = PlacesSnapshot(favorites: favorites, recents: recents)
                snapshot.record(SavedPlace(name: name, coordinate: coordinate))
                savePlaces(snapshot)
            case .clear:
                isSimulating = false
                locationMonitor.stop()
                developerStatus = "恢复指令已完成, 会话已关闭"
                lastOperation = "最近操作: 已发送恢复真实定位指令"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            isSimulating = false
            locationMonitor.stop()
            await LocationEngine.disconnect()
            lastOperation = "状态未知"
            developerStatus = "连接或指令未完成"
            if engineAttempted { developerStatus += " / " + (await LocationEngine.lastFailureDetails()) }
            report(error as? AuroraLocationError ?? .pairingInvalid)
        }
        if !isSimulating { relayStatus = await ShadowrocketTunnel.stop() }
        isBusy = false
    }

    func checkConnection() async {
        guard !isBusy, !pairing.isBusy else { report(.busy); return }
        guard !isSimulating else {
            developerStatus = "定位会话已保留, 恢复真实定位后可重新检测"
            return
        }
        isBusy = true
        errorMessage = nil
        var engineAttempted = false
        do {
            try await prepareConnection()
            engineAttempted = true
            try await LocationEngine.perform(nil, pairingPath: PairingStore.fileURL().path)
            developerStatus = "检测成功, 会话已关闭"
            lastErrorCode = "none"
        } catch {
            developerStatus = "检测未完成"
            if engineAttempted { developerStatus += " / " + (await LocationEngine.lastFailureDetails()) }
            report(error as? AuroraLocationError ?? .pairingInvalid)
        }
        relayStatus = await ShadowrocketTunnel.stop()
        isBusy = false
    }

    private func prepareConnection() async throws {
        wifiAvailable = NetworkStatus.hasWiFiAddress
        pairing.refresh()
        guard pairing.hasPairing else { showSetup = true; throw AuroraLocationError.pairingMissing }
        try await ShadowrocketTunnel.start()
        relayStatus = "本机中继已启动"
        if isSimulating {
            developerStatus = "正在发送指令"
            return
        }
        tunnelStatus = "正在检测"
        let reachable = await NetworkStatus.probeTunnel()
        tunnelStatus = reachable ? "本机端口可达" : "本机端口不可达"
        guard reachable else { throw AuroraLocationError.tunnelUnavailable }
        developerStatus = "正在连接"
    }

    private func startMaintenance(_ coordinate: Coordinate, pairingPath: String) {
        // Refresh the applied coordinate, not the map selection. No history writes or haptics.
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) }
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
        do {
            try await LocationEngine.perform(.set(coordinate), pairingPath: pairingPath)
            locationMonitor.recordDebugEvent("maintenanceSet")
            return true
        } catch {
            // ponytail: stop on disconnect; add bounded reconnect after handshake recovery is validated.
            stopMaintenance()
            isSimulating = false
            locationMonitor.stop()
            lastOperation = "定位保持中断, 状态未知"
            developerStatus = "保持指令未完成 / " + (await LocationEngine.lastFailureDetails())
            report(error as? AuroraLocationError ?? .locationSimulationFailed)
            relayStatus = await ShadowrocketTunnel.stop()
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
        tunnel: \(tunnelStatus)
        developerService: \(developerStatus)
        relay: \(relayStatus)
        errorCode: \(lastErrorCode)
        """
    }

    func handleURL(_ url: URL) {
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
        locationMonitor.recordDebugEvent("error=\(error.rawValue) wifi=\(NetworkStatus.hasWiFiAddress) detail=\(developerStatus)")
        lastErrorCode = error.rawValue
        errorMessage = error.localizedDescription
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
