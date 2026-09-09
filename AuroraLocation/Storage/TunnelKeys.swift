import CryptoKit
import Foundation

struct TunnelKeys: Codable {
    let serverPrivateKey: Data
    let clientPrivateKey: Data

    var serverPublicKey: Data {
        get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverPrivateKey).publicKey.rawRepresentation }
    }

    var clientPublicKey: Data {
        get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivateKey).publicKey.rawRepresentation }
    }

    var wireGuardConfiguration: String {
        get throws {
            _ = try clientPublicKey
            return """
            [Interface]
            PrivateKey = \(clientPrivateKey.base64EncodedString())
            Address = 10.7.0.10/24

            [Peer]
            PublicKey = \(try serverPublicKey.base64EncodedString())
            AllowedIPs = 10.7.0.1/32
            Endpoint = 127.0.0.1:51820
            PersistentKeepalive = 25

            """
        }
    }

    static func loadOrCreate() throws -> TunnelKeys {
        let url = try LocalStore.directory("Tunnel").appendingPathComponent("keys.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let keys = try JSONDecoder().decode(TunnelKeys.self, from: Data(contentsOf: url))
            _ = try keys.serverPublicKey
            _ = try keys.clientPublicKey
            return keys
        }
        let keys = TunnelKeys(
            serverPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            clientPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        // Keep the existing Shadowrocket peer valid across app launches and updates.
        try LocalStore.write(JSONEncoder().encode(keys), to: url)
        return keys
    }
}
