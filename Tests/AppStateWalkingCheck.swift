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

enum NetworkStatus {
    static let hasWiFiAddress = true
    static let interfaceSummary = "test"
    static func probeTunnel() async -> (reachable: Bool, details: String) { (true, "test") }
}

@MainActor enum ShadowrocketTunnel {
    static var running = false
    static func start() async throws { running = true }
    static func stop() async -> String { running = false; return "stopped" }
    static func snapshot() async -> String { running ? "running" : "stopped" }
}

@MainActor enum LocationEngine {
    static var commands: [LocationCommand] = []
    static var failNext = false
    static var inFlight = false
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
    }
    static func disconnect() async {}
    static func lastFailureDetails() async -> String { "test failure" }
}

enum DiagnosticLog {
    static func begin(_ operation: String) {}
    static func event(_ message: String) {}
    static func report() -> String { "test" }
}

enum UIDevice {
    static let current = TestDevice()
    struct TestDevice { let systemVersion = "test" }
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
        let state = AppState()
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
    }
}
