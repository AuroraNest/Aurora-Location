import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable {
    case existing
    case auroraVPN

    static let storageKey = "locationConnectionMode"
    static var saved: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .existing
    }

    var id: String { rawValue }
}

enum AuroraVPN {
    static let callbackScheme = "auroralocation-vpn"

    enum Result: String {
        case ready, cancel, error
    }

    struct Request {
        let id: UUID
        let deadline: TimeInterval
        private(set) var consumed = false

        init(id: UUID = UUID(), now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            self.id = id
            deadline = now + 180
        }

        var url: URL {
            var parts = URLComponents()
            parts.scheme = "auroravpn"
            parts.host = "connect"
            parts.queryItems = [URLQueryItem(name: "request", value: id.uuidString)]
            return parts.url!
        }

        mutating func consume(_ url: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Result? {
            guard !consumed, now <= deadline,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == AuroraVPN.callbackScheme, parts.host == "callback",
                  parts.path.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.fragment == nil,
                  let items = parts.queryItems, items.count == 2,
                  Set(items.map(\.name)) == ["request", "result"],
                  items.allSatisfy({ $0.value != nil }) else { return nil }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            guard values["request"].flatMap(UUID.init(uuidString:)) == id,
                  let result = values["result"].flatMap(Result.init(rawValue:)) else { return nil }
            consumed = true
            return result
        }
    }
}
