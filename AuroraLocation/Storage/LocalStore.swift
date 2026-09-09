import Foundation

enum LocalStore {
    static func directory(_ name: String) throws -> URL {
        var url = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete,
            .posixPermissions: 0o700], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct PlacesSnapshot: Codable {
    var favorites: [SavedPlace] = []
    var recents: [SavedPlace] = []

    mutating func record(_ place: SavedPlace) {
        recents.removeAll { $0.coordinate == place.coordinate }
        recents.insert(place, at: 0)
        recents = Array(recents.prefix(20))
    }

    func validate() throws {
        guard favorites.allSatisfy({ $0.coordinate.isValid }),
              recents.allSatisfy({ $0.coordinate.isValid }), recents.count <= 20,
              Set(favorites.map(\.id)).count == favorites.count,
              Set(recents.map(\.id)).count == recents.count else {
            throw AuroraLocationError.storageFailed
        }
    }
}

enum PlacesStore {
    static func load() throws -> PlacesSnapshot {
        let url = try LocalStore.directory("Places").appendingPathComponent("places.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PlacesSnapshot(favorites: [SavedPlace(name: "Times Square", coordinate: .timesSquare)])
        }
        let snapshot = try JSONDecoder().decode(PlacesSnapshot.self, from: Data(contentsOf: url))
        try snapshot.validate()
        return snapshot
    }

    static func save(_ snapshot: PlacesSnapshot) throws {
        try snapshot.validate()
        let url = try LocalStore.directory("Places").appendingPathComponent("places.json")
        try LocalStore.write(JSONEncoder().encode(snapshot), to: url)
    }
}
