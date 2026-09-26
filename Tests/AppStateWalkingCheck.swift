import Foundation
import Combine

// In-memory boundaries let the actual AppState scheduler run without a phone or stored credentials.
@MainActor final class PairingService: ObservableObject {
    var hasPairing = true
    var isBusy = false
    func refresh() {}
}

@MainActor final class LocationMonitor {
    var target: Coordinate?
    func recordDebugEvent(_ event: String) {}
    func setTarget(_ coordinate: Coordinate) { target = coordinate }
    func moveTarget(to coordinate: Coordinate) { target = coordinate }
    func stop() { target = nil }
}

enum PairingStore {
    static func fileURL() throws -> URL { URL(fileURLWithPath: "/test/unused-pairing") }
}

struct PlacesSnapshot {
    var favorites: [SavedPlace] = []
    var recents: [SavedPlace] = []
    mutating func record(_ place: SavedPlace) { recents.insert(place, at: 0) }
}

@MainActor enum PlacesStore {
    static var saved = PlacesSnapshot()
    static func load() throws -> PlacesSnapshot { saved }
    static func save(_ snapshot: PlacesSnapshot) throws { saved = snapshot }
}

@MainActor enum NetworkStatus {
    static var hasWiFiAddress = true
    static let interfaceSummary = "test"
    static var probeCount = 0
    static func probeTunnel(viaLocalProxy: Bool = false) async -> (reachable: Bool, details: String) {
        probeCount += 1
        return (true, "test")
    }
    static func probeLoopback(restrictListener: Bool = false, peerToPeer: Bool = false) async -> (reachable: Bool, details: String) {
        (true, "test")
    }
}

@MainActor enum ShadowrocketTunnel {
    static var running = false
    static var startCount = 0
    static var stopCount = 0
    static var snapshotCount = 0
    static func start() async throws { startCount += 1; running = true }
    static func stop() async -> String { stopCount += 1; running = false; return "stopped" }
    static func snapshot() async -> String {
        snapshotCount += 1
        return running ? "running" : "stopped"
    }
}

@MainActor enum LocalDeviceTunnel {
    static var lastFailureDetails = "startTunnel: NEVPNErrorDomain code=1."
    static var isConnected = false
    static var startCount = 0
    static var stopCount = 0
    static var failStart = false
    static var stopSucceeds = true
    static func start() async throws {
        startCount += 1
        if failStart { throw AuroraLocationError.localTunnelFailed }
        isConnected = true
    }
    static func stop() async -> Bool {
        stopCount += 1
        if stopSucceeds { isConnected = false }
        return stopSucceeds
    }
}

@MainActor enum LocationEngine {
    static var commands: [LocationCommand] = []
    static var failNext = false
    static var inFlight = false
    static var checkCount = 0
    static func perform(_ command: LocationCommand?, pairingPath: String) async throws {
        assert(!inFlight, "Commands must remain serialized")
        inFlight = true
        defer { inFlight = false }
        try await Task.sleep(for: .milliseconds(25))
        if failNext {
            failNext = false
            throw AuroraLocationError.locationSimulationFailed
        }
        if let command { commands.append(command) }
        else { checkCount += 1 }
    }
    static func disconnect() async {}
    static func lastFailureDetails() async -> String { "test failure" }
}

enum DiagnosticLog {
    static let enabled = false
    static func begin(_ operation: String) {}
    static func event(_ message: String) {}
    static func report() -> String { "test" }
}

enum UIDevice {
    static let current = TestDevice()
    struct TestDevice { let systemVersion = "test" }
}

@MainActor final class UIApplication {
    static let shared = UIApplication()
    var openedURLs: [URL] = []
    var openSucceeds = true
    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return openSucceeds
    }
}

@main struct AppStateWalkingCheck {
    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Timed out waiting for walking state")
    }

    @MainActor static func main() async throws {
        let savedMode = UserDefaults.standard.object(forKey: ConnectionMode.storageKey)
        UserDefaults.standard.removeObject(forKey: ConnectionMode.storageKey)
        defer { UserDefaults.standard.set(savedMode, forKey: ConnectionMode.storageKey) }
        try await automaticCellularCheck()
        let state = AppState()
        await state.checkConnection()
        assert(NetworkStatus.probeCount == 1 && LocationEngine.checkCount == 1)
        #if DEBUG
        state.handleURL(URL(string: "auroralocation://check-native?unexpected=1")!)
        assert(LocationEngine.checkCount == 1 && !state.isBusy)
        state.handleURL(URL(string: "auroralocation://check-native")!)
        try await eventually { LocationEngine.checkCount == 2 && !state.isBusy }
        assert(NetworkStatus.probeCount == 1 && LocationEngine.commands.isEmpty && !ShadowrocketTunnel.running)
        #endif
        let origin = Coordinate.timesSquare
        let route = WalkingRoute(coordinates: [origin,
            Coordinate(latitude: origin.latitude + 0.001, longitude: origin.longitude)])!
        await state.startWalking(route: route, speedKmh: .nan)
        assert(LocationEngine.commands.isEmpty && !state.isSimulating)

        await state.startWalking(route: route, speedKmh: 4.5)
        assert(state.isWalkingSessionActive && state.walkingSession?.distanceTraveled == 0)
        assert(LocationEngine.commands.last == .set(origin))
        let historyCount = state.recents.count
        try await eventually { !state.isBusy && (state.walkingSession?.distanceTraveled ?? 0) > 0 }
        assert(state.recents.count == historyCount, "Walking ticks must not create history entries")
        assert(state.locationMonitor.target == state.walkingSession?.coordinate)

        state.pauseWalking()
        let paused = state.walkingSession!
        let pausedCount = LocationEngine.commands.count
        try await eventually { !state.isBusy && LocationEngine.commands.count > pausedCount }
        assert(state.walkingSession?.phase == .paused)
        assert(state.walkingSession?.distanceTraveled == paused.distanceTraveled)
        assert(LocationEngine.commands.last == .set(paused.coordinate), "Pause must keep sending its fixed point")

        let unrelated = Coordinate(latitude: 1, longitude: 2)
        state.select(unrelated)
        let countBeforeSet = LocationEngine.commands.count
        await state.execute(.set(unrelated))
        assert(LocationEngine.commands.count == countBeforeSet && state.isWalkingSessionActive)
        state.resumeWalking()
        try await eventually { !state.isBusy && (state.walkingSession?.distanceTraveled ?? 0) > paused.distanceTraveled }
        assert(state.walkingSession?.phase == .walking)
        assert(LocationEngine.commands.last != .set(unrelated), "Map selection cannot redirect the active route")

        let beforeFailure = state.walkingSession!.distanceTraveled
        LocationEngine.failNext = true
        try await eventually { !state.isBusy && state.walkingSession?.phase == .interrupted }
        assert(!state.isSimulating && !ShadowrocketTunnel.running && state.locationMonitor.target == nil)
        assert(state.walkingSession?.distanceTraveled == beforeFailure, "A failed command must not advance published progress")
        let stoppedCount = LocationEngine.commands.count
        state.resumeWalking()
        try await Task.sleep(for: .milliseconds(1200))
        assert(LocationEngine.commands.count == stoppedCount && !state.isWalkingSessionActive)

        let tinyRoute = WalkingRoute(coordinates: [origin,
            Coordinate(latitude: origin.latitude + 0.000001, longitude: origin.longitude)])!
        await state.startWalking(route: tinyRoute, speedKmh: 4.5)
        try await eventually { !state.isBusy && state.walkingSession?.phase == .arrived }
        assert(state.isWalkingSessionActive && state.walkingSession?.progress == 1)
        assert(LocationEngine.commands.last == .set(tinyRoute.coordinates.last!))
        let arrivalCount = LocationEngine.commands.count
        try await eventually { !state.isBusy && LocationEngine.commands.count > arrivalCount }
        assert(LocationEngine.commands.last == .set(tinyRoute.coordinates.last!))

        await state.execute(.clear)
        assert(state.walkingSession == nil && !state.isSimulating && !ShadowrocketTunnel.running)
        assert(LocationEngine.commands.last == .clear)
        let clearCount = LocationEngine.commands.count
        try await Task.sleep(for: .milliseconds(1200))
        assert(LocationEngine.commands.count == clearCount, "Clear must cancel future walking writes")

        await state.execute(.set(unrelated))
        assert(state.isSimulating && state.walkingSession == nil)
        await state.execute(.clear)
        print("PASS: walking scheduler advances only on success, pause/arrival hold, clear cancels, failure stops, fixed mode remains usable")

        let beforeOutdoor = LocationEngine.commands.count
        await state.prepareOutdoor()
        await state.executeOutdoor()
        assert(LocationEngine.commands.count == beforeOutdoor && LocalDeviceTunnel.startCount == 0)
        NetworkStatus.hasWiFiAddress = false
        let probesBeforePreparation = NetworkStatus.probeCount
        await state.prepareOutdoor()
        assert(state.isOutdoorPrepared && LocalDeviceTunnel.isConnected && !state.isSimulating)
        assert(LocationEngine.commands.count == beforeOutdoor && NetworkStatus.probeCount == probesBeforePreparation,
               "VPN preparation must not probe the developer service or send location commands")
        state.enteredBackground()
        state.refresh()
        assert(state.isOutdoorPrepared && LocalDeviceTunnel.isConnected,
               "Keep the prepared VPN alive while cellular is switched off")
        await state.cancelOutdoorPreparation()
        assert(!state.isOutdoorPrepared && !LocalDeviceTunnel.isConnected && !state.isOutdoorMode)
        assert(state.developerStatus == "尚未检测" && state.tunnelStatus == "尚未检测")
        assert(LocationEngine.commands.count == beforeOutdoor, "Cancelling preparation must not send clear")
        await state.prepareOutdoor()
        await state.executeOutdoor()
        assert(!state.isOutdoorPrepared && state.isOutdoorMode && state.isSimulating && LocalDeviceTunnel.isConnected && !ShadowrocketTunnel.running)
        assert(LocationEngine.commands.last == .set(unrelated))
        let starts = LocalDeviceTunnel.startCount
        state.select(origin)
        await state.executeOutdoor()
        assert(LocalDeviceTunnel.startCount == starts && LocationEngine.commands.last == .set(origin))
        await state.execute(.clear)
        assert(!state.isOutdoorMode && !state.isSimulating && !LocalDeviceTunnel.isConnected)

        LocalDeviceTunnel.failStart = true
        let beforeStartFailure = LocationEngine.commands.count
        await state.prepareOutdoor()
        assert(!state.isOutdoorPrepared && !LocalDeviceTunnel.isConnected && LocationEngine.commands.count == beforeStartFailure)
        await state.executeOutdoor()
        assert(LocationEngine.commands.count == beforeStartFailure && !state.isSimulating && !ShadowrocketTunnel.running)
        assert(state.errorMessage?.contains(LocalDeviceTunnel.lastFailureDetails) == true)
        assert(state.errorMessage?.contains("允许添加") == false)
        LocalDeviceTunnel.failStart = false
        LocationEngine.failNext = true
        await state.executeOutdoor()
        assert(!state.isSimulating && !LocalDeviceTunnel.isConnected && !ShadowrocketTunnel.running)

        LocalDeviceTunnel.stopSucceeds = false
        await state.execute(.set(origin))
        assert(!state.isSimulating && !ShadowrocketTunnel.running, "Never start the default path before our VPN is confirmed stopped")
        LocalDeviceTunnel.stopSucceeds = true
        NetworkStatus.hasWiFiAddress = true
        await state.execute(.set(origin))
        assert(!state.isOutdoorMode && state.isSimulating && ShadowrocketTunnel.running && !LocalDeviceTunnel.isConnected)
        let beforeSwitch = LocalDeviceTunnel.startCount
        await state.executeOutdoor()
        assert(LocalDeviceTunnel.startCount == beforeSwitch && state.isSimulating && !state.isOutdoorMode)
        await state.execute(.clear)
        print("PASS: outdoor Wi-Fi guard, local-only startup/reuse/clear/failure, safe mode switch and unchanged default transport")
        try await externalModeCheck()
        assert(ShadowrocketTunnel.snapshotCount == 0, "Disabled diagnostics must skip relay snapshots")
        print("PASS: diagnostics off skips relay snapshots across connection and location flows")
    }

    @MainActor static func externalModeCheck() async throws {
        let localStarts = LocalDeviceTunnel.startCount
        let localStops = LocalDeviceTunnel.stopCount
        let relayStarts = ShadowrocketTunnel.startCount
        let relayStops = ShadowrocketTunnel.stopCount
        let origin = Coordinate.timesSquare
        let app = UIApplication.shared

        func reply(_ launch: URL, result: String) -> URL {
            let request = URLComponents(url: launch, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "request" }!.value!
            return URL(string: "auroralocation-vpn://callback?request=\(request)&result=\(result)")!
        }
        func cellularReply(_ launch: URL) -> URL {
            let input = URLComponents(url: launch, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "text" }!.value!.split(separator: "\n")
            return URL(string: String(input[1]))!
        }
        func assertNoOwnedVPNCalls() {
            assert(LocalDeviceTunnel.startCount == localStarts && LocalDeviceTunnel.stopCount == localStops)
            assert(ShadowrocketTunnel.startCount == relayStarts && ShadowrocketTunnel.stopCount == relayStops)
        }

        let state = AppState()
        state.connectionMode = .auroraVPN
        let beforeSet = LocationEngine.commands.count
        let setTask = Task { await state.execute(.set(origin)) }
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" }
        let launch = app.openedURLs.last!
        assert(state.isBusy && LocationEngine.commands.count == beforeSet)
        state.handleURL(URL(string: reply(launch, result: "ready").absoluteString + "&lat=1")!)
        assert(state.isBusy && LocationEngine.commands.count == beforeSet)
        state.handleURL(reply(launch, result: "ready"))
        await setTask.value
        assert(state.isSimulating && LocationEngine.commands.last == .set(origin))
        assertNoOwnedVPNCalls()
        await state.execute(.clear)
        assert(!state.isSimulating && LocationEngine.commands.last == .clear)
        assertNoOwnedVPNCalls()
        let beforeCheckLaunch = app.openedURLs.last!
        let checkTask = Task { await state.checkConnection() }
        try await eventually { app.openedURLs.last != beforeCheckLaunch }
        assert(app.openedURLs.last?.scheme == "auroravpn")
        state.handleURL(reply(app.openedURLs.last!, result: "ready"))
        await checkTask.value
        assertNoOwnedVPNCalls()
        let beforeReconnectLaunch = app.openedURLs.last!
        let beforeReconnectSet = LocationEngine.commands.count
        let reconnectTask = Task { await state.execute(.set(origin)) }
        try await eventually { app.openedURLs.last != beforeReconnectLaunch }
        assert(app.openedURLs.last?.scheme == "auroravpn" && LocationEngine.commands.count == beforeReconnectSet,
               "After clear/check, the next set must wait for fresh Aurora VPN readiness")
        state.handleURL(reply(beforeReconnectLaunch, result: "ready"))
        assert(LocationEngine.commands.count == beforeReconnectSet, "An old callback must not replay set")
        state.handleURL(reply(app.openedURLs.last!, result: "ready"))
        await reconnectTask.value
        assert(state.isSimulating && LocationEngine.commands.count == beforeReconnectSet + 1)
        assertNoOwnedVPNCalls()
        LocationEngine.failNext = true
        await state.execute(.clear)
        assert(!state.isSimulating && state.errorMessage != nil)
        assertNoOwnedVPNCalls()

        let failed = AppState()
        assert(failed.connectionMode == .auroraVPN, "Selected mode must survive a new AppState")
        let beforeFailure = LocationEngine.commands.count
        let beforeFailedLaunch = app.openedURLs.last!
        let failedTask = Task { await failed.execute(.set(origin)) }
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" && app.openedURLs.last != beforeFailedLaunch }
        failed.handleURL(reply(app.openedURLs.last!, result: "error"))
        await failedTask.value
        assert(!failed.isSimulating && LocationEngine.commands.count == beforeFailure)
        assertNoOwnedVPNCalls()

        let cancelled = AppState()
        let failedLaunch = app.openedURLs.last!
        let cancelTask = Task { await cancelled.execute(.set(origin)) }
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" && app.openedURLs.last != failedLaunch }
        assert(cancelled.canCancelAuroraVPN)
        cancelled.cancelAuroraVPNConnection()
        await cancelTask.value
        cancelled.handleURL(reply(app.openedURLs.last!, result: "ready"))
        assert(!cancelled.isSimulating && LocationEngine.commands.count == beforeFailure)
        assertNoOwnedVPNCalls()

        app.openSucceeds = false
        let unopened = AppState()
        await unopened.execute(.set(origin))
        assert(unopened.errorMessage?.contains("无法打开 Aurora VPN") == true)
        assert(!unopened.isSimulating && LocationEngine.commands.count == beforeFailure)
        app.openSucceeds = true
        assertNoOwnedVPNCalls()

        let walking = AppState()
        let route = WalkingRoute(coordinates: [origin,
            Coordinate(latitude: origin.latitude + 0.001, longitude: origin.longitude)])!
        let unopenedLaunch = app.openedURLs.last!
        let walkTask = Task { await walking.startWalking(route: route, speedKmh: 4.5) }
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" && app.openedURLs.last != unopenedLaunch }
        walking.handleURL(reply(app.openedURLs.last!, result: "ready"))
        await walkTask.value
        assert(walking.isWalkingSessionActive)
        await walking.execute(.clear)
        assertNoOwnedVPNCalls()

        NetworkStatus.hasWiFiAddress = false
        let cancelledCellular = AppState()
        await cancelledCellular.startAutomaticOutdoor()
        cancelledCellular.handleURL(cellularReply(app.openedURLs.last!))
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" }
        let cancelledCellularLaunch = app.openedURLs.last!
        await cancelledCellular.cancelAutomaticOutdoor()
        try await eventually { !cancelledCellular.isBusy }
        cancelledCellular.handleURL(reply(cancelledCellularLaunch, result: "ready"))
        assert(!cancelledCellular.isSimulating && !cancelledCellular.needsCellularRecovery)
        assertNoOwnedVPNCalls()

        let cellular = AppState()
        let beforeCellularSet = LocationEngine.commands.count
        await cellular.startAutomaticOutdoor()
        assert(app.openedURLs.last?.scheme == "shortcuts")
        cellular.handleURL(cellularReply(app.openedURLs.last!))
        try await eventually { app.openedURLs.last?.scheme == "auroravpn" }
        assert(cellular.canCancelAutomaticOutdoor && LocationEngine.commands.count == beforeCellularSet)
        cellular.handleURL(reply(app.openedURLs.last!, result: "ready"))
        try await eventually { app.openedURLs.last?.absoluteString.contains("text=offline") == true }
        cellular.handleURL(cellularReply(app.openedURLs.last!))
        try await eventually { app.openedURLs.last?.absoluteString.contains("text=restore") == true }
        cellular.handleURL(cellularReply(app.openedURLs.last!))
        try await eventually { !cellular.isBusy }
        assert(cellular.isSimulating && LocationEngine.commands.last == .set(origin))
        await cellular.execute(.clear)
        assertNoOwnedVPNCalls()
        NetworkStatus.hasWiFiAddress = true
        print("PASS: Aurora VPN mode retains external transport across set/clear/check/walking/cellular and rejects failure/cancel/open error")
    }

    @MainActor static func automaticCellularCheck() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CellularShortcut.recoveryKey)
        defer {
            defaults.removeObject(forKey: CellularShortcut.recoveryKey)
            defaults.removeObject(forKey: CellularShortcut.installedKey)
            LocationEngine.commands = []
            LocationEngine.checkCount = 0
            NetworkStatus.probeCount = 0
            NetworkStatus.hasWiFiAddress = true
            LocalDeviceTunnel.startCount = 0
            LocalDeviceTunnel.isConnected = false
        }
        func callback(_ launch: URL, outcome: String = "success") -> URL {
            let fields = URLComponents(url: launch, resolvingAgainstBaseURL: false)!.queryItems!
            assert(launch.host == "run-shortcut" && !fields.contains { $0.name.hasPrefix("x-") })
            let input = fields.first { $0.name == "text" }!.value!.split(separator: "\n")
            assert(input.count == 2)
            var parts = URLComponents(string: String(input[1]))!
            assert(parts.queryItems!.first { $0.name == "phase" }!.value! == input[0])
            parts.queryItems!.removeAll { $0.name == "outcome" }
            parts.queryItems!.append(URLQueryItem(name: "outcome", value: outcome))
            return parts.url!
        }
        var request = CellularShortcut.Request(phase: .prepare, now: 0)
        let valid = callback(request.url)
        assert(request.consume(URL(string: valid.absoluteString + "&token=duplicate")!, now: 1) == nil)
        assert(request.consume(valid, now: 181) == nil)
        assert(request.consume(valid, now: 1) == .success)
        assert(request.consume(valid, now: 2) == nil)
        var oldHelper = CellularShortcut.Request(phase: .prepare, now: 0)
        var oldReply = URLComponents(url: callback(oldHelper.url), resolvingAgainstBaseURL: false)!
        oldReply.queryItems!.removeAll { $0.name == "result" }
        oldReply.queryItems!.append(URLQueryItem(name: "result", value: "aurora-cellular-v1:prepare"))
        assert(oldHelper.consume(oldReply.url!, now: 1) == .error)
        var failed = CellularShortcut.Request(phase: .prepare, now: 0)
        var systemError = URLComponents(url: callback(failed.url, outcome: "error"), resolvingAgainstBaseURL: false)!
        systemError.path = "/"
        systemError.queryItems! += [URLQueryItem(name: "errorDomain", value: "WFOutOfProcessWorkflowControllerErrorDomain"), URLQueryItem(name: "errorCode", value: "4")]
        assert(failed.consume(systemError.url!, now: 1) == .error)

        NetworkStatus.hasWiFiAddress = false
        let state = AppState()
        await state.startAutomaticOutdoor()
        assert(LocationEngine.commands.isEmpty && !state.needsCellularRecovery)
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { state.needsCellularRecovery }
        assert(LocationEngine.commands.isEmpty)
        let offline = callback(UIApplication.shared.openedURLs.last!)
        let target = state.selected
        state.select(Coordinate(latitude: 1, longitude: 2))
        state.handleURL(offline)
        try await eventually { UIApplication.shared.openedURLs.last!.absoluteString.contains("text=restore") }
        assert(LocationEngine.commands.count == 1)
        if case let .set(coordinate) = LocationEngine.commands[0] { assert(coordinate == target) }
        else { assertionFailure("Expected set") }
        state.handleURL(offline)
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { !state.isBusy }
        assert(!state.needsCellularRecovery && LocationEngine.commands.count == 1)
        await state.execute(.clear)

        await state.startAutomaticOutdoor()
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { state.needsCellularRecovery }
        await state.cancelAutomaticOutdoor()
        assert(UIApplication.shared.openedURLs.last!.absoluteString.contains("text=restore"))
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { !state.isBusy }
        assert(!state.needsCellularRecovery)

        await state.startAutomaticOutdoor()
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { state.needsCellularRecovery }
        LocationEngine.failNext = true
        state.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { UIApplication.shared.openedURLs.last!.absoluteString.contains("text=restore") }
        state.handleURL(callback(UIApplication.shared.openedURLs.last!, outcome: "error"))
        try await eventually { !state.isBusy }
        assert(state.needsCellularRecovery && !state.isSimulating && state.errorMessage != nil)

        defaults.set(true, forKey: CellularShortcut.recoveryKey)
        let restarted = AppState()
        let count = LocationEngine.commands.count
        await restarted.resumeCellularRecovery()
        assert(UIApplication.shared.openedURLs.last!.absoluteString.contains("text=restore"))
        restarted.handleURL(callback(UIApplication.shared.openedURLs.last!))
        try await eventually { !restarted.isBusy }
        assert(!restarted.needsCellularRecovery && LocationEngine.commands.count == count)
        print("PASS: automatic callbacks reject replay/expiry, snapshot target, restore after cancel and recover without replaying set")
    }
}
