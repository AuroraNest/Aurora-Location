import Foundation
import CryptoKit

func parse(_ value: String) throws -> LocationCommand {
    try LocationCommand(url: URL(string: value)!)
}

let set = try parse("auroralocation://set?lat=40.7580&lon=-73.9855")
let clear = try parse("auroralocation://clear")
let boundary = try parse("auroralocation://set?lon=180&lat=-90")
assert(set == .set(.timesSquare))
assert(clear == .clear)
assert(boundary == .set(Coordinate(latitude: -90, longitude: 180)))
for invalid in [
    "https://set?lat=0&lon=0", "auroralocation://set?lat=91&lon=0",
    "auroralocation://set?lat=0&lon=-181", "auroralocation://set?lat=nan&lon=0",
    "auroralocation://set?lat=inf&lon=0", "auroralocation://set?lat=0&lat=1&lon=0",
    "auroralocation://set?lat=0", "auroralocation://set?lat=&lon=0",
    "auroralocation://set?lat=0&lon=0&extra=1", "auroralocation://set/path?lat=0&lon=0",
    "auroralocation://user@set?lat=0&lon=0", "auroralocation://set:80?lat=0&lon=0",
    "auroralocation://clear?lat=0", "auroralocation://clear#fragment", "auroralocation://unknown"
] {
    do { _ = try parse(invalid); assertionFailure("Accepted invalid URL: \(invalid)") }
    catch { assert(error is AuroraLocationError) }
}
assert(!Coordinate(latitude: .infinity, longitude: 0).isValid)
assert(!Coordinate(latitude: 0, longitude: .nan).isValid)
let original = SavedPlace(name: "Times Square", coordinate: .timesSquare)
let decoded = try JSONDecoder().decode(SavedPlace.self, from: JSONEncoder().encode(original))
assert(decoded == original)
var snapshot = PlacesSnapshot()
for latitude in 0..<25 {
    snapshot.record(SavedPlace(name: "Place \(latitude)", coordinate: Coordinate(latitude: Double(latitude), longitude: 0)))
}
assert(snapshot.recents.count == 20 && snapshot.recents.first?.coordinate.latitude == 24)
snapshot.record(SavedPlace(name: "Renamed", coordinate: Coordinate(latitude: 24, longitude: 0)))
assert(snapshot.recents.count == 20 && snapshot.recents.first?.name == "Renamed")
try snapshot.validate()
let tunnelKeys = TunnelKeys(serverPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
    clientPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
let restoredKeys = try JSONDecoder().decode(TunnelKeys.self, from: JSONEncoder().encode(tunnelKeys))
let serverPublic = try restoredKeys.serverPublicKey
let clientPublic = try restoredKeys.clientPublicKey
assert(serverPublic.count == 32 && clientPublic.count == 32 && serverPublic != clientPublic)
let peerConfig = try restoredKeys.wireGuardConfiguration
assert(peerConfig.contains("AllowedIPs = 10.7.0.1/32"))
assert(peerConfig.contains("Endpoint = 127.0.0.1:51820"))
assert(!peerConfig.contains(restoredKeys.serverPrivateKey.base64EncodedString()))
do {
    _ = try TunnelKeys(serverPrivateKey: Data(), clientPrivateKey: Data()).serverPublicKey
    assertionFailure("Accepted malformed tunnel key")
} catch {}
print("PASS: URL validation, finite coordinate bounds, storage round trip, recent deduplication and 20-item limit")
print("PASS: tunnel key round trip and malformed key rejection")
