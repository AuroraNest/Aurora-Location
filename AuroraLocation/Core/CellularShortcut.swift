import Foundation

enum CellularShortcut {
    static let name = "Aurora 蜂窝助手 2"
    static let scheme = "auroralocation-cellular"
    static let recoveryKey = "cellularShortcutRecoveryNeeded"
    static let installedKey = "cellularShortcutV2Installed"

    enum Phase: String {
        case prepare, offline, restore

        var acknowledgement: String { "aurora-cellular-v2:\(rawValue)" }
    }

    enum Outcome: String {
        case success, cancel, error
    }

    struct Request {
        let phase: Phase
        let token = UUID().uuidString
        let deadline: TimeInterval
        private(set) var consumed = false

        init(phase: Phase, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            self.phase = phase
            deadline = now + 180
        }

        var url: URL {
            var parts = URLComponents()
            parts.scheme = "shortcuts"
            parts.host = "run-shortcut"
            parts.queryItems = [
                URLQueryItem(name: "name", value: CellularShortcut.name),
                URLQueryItem(name: "input", value: "text"),
                URLQueryItem(name: "text", value: phase.rawValue + "\n" + callback.absoluteString)
            ]
            return parts.url!
        }

        private var callback: URL {
            var parts = URLComponents()
            parts.scheme = CellularShortcut.scheme
            parts.host = "callback"
            parts.queryItems = [URLQueryItem(name: "token", value: token),
                                URLQueryItem(name: "phase", value: phase.rawValue),
                                URLQueryItem(name: "outcome", value: Outcome.success.rawValue),
                                URLQueryItem(name: "result", value: phase.acknowledgement)]
            return parts.url!
        }

        mutating func consume(_ url: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Outcome? {
            guard !consumed, now <= deadline,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == CellularShortcut.scheme, parts.host == "callback",
                  ["", "/"].contains(parts.path), parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.fragment == nil else { return nil }
            let items = parts.queryItems ?? []
            let allowed: Set<String> = ["token", "phase", "outcome", "result", "errorMessage", "errorCode", "errorDomain"]
            guard items.allSatisfy({ allowed.contains($0.name) && $0.value != nil }),
                  Set(items.map(\.name)).count == items.count else { return nil }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            guard values["token"] == token, values["phase"] == phase.rawValue,
                  let outcome = values["outcome"].flatMap(Outcome.init(rawValue:)) else { return nil }
            consumed = true
            // An imported shortcut with the wrong contents must not advance the location flow.
            if outcome == .success,
               values["result"]?.trimmingCharacters(in: .whitespacesAndNewlines) != phase.acknowledgement {
                return .error
            }
            return outcome
        }
    }
}
