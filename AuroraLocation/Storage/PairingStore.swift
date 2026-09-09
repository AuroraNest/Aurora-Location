import Foundation
import idevice

enum PairingStore {
    static func fileURL() throws -> URL {
        try LocalStore.directory("Pairing").appendingPathComponent("rp_pairing_file.plist")
    }

    static func exists() -> Bool {
        guard let url = try? fileURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func serialize(_ handle: OpaquePointer) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        if let error = rp_pairing_file_to_bytes(handle, &bytes, &length) {
            idevice_error_free(error)
            throw AuroraLocationError.pairingSaveFailed
        }
        guard let bytes, length > 0 else { throw AuroraLocationError.pairingSaveFailed }
        defer { idevice_data_free(bytes, UInt(length)) }
        // The FFI never writes an unprotected intermediate credential file.
        return Data(bytes: bytes, count: length)
    }

    static func save(_ data: Data) throws {
        try LocalStore.write(data, to: fileURL())
    }
}
