import CryptoKit
import Foundation
import Security

/// Everything sensitive is AES-GCM sealed before it touches disk; the key lives
/// in the Keychain.
///
/// What this buys: the database file is useless on its own — in a backup, in a
/// synced folder, copied to a stick. What it does NOT buy: protection from code
/// running as you, which can just ask the Keychain or read the clipboard
/// directly. It narrows the surface, it isn't armour.
enum Crypto {
    enum Failure: Error {
        case keychain(OSStatus)
        case corrupted
    }

    private static let service = "io.local.clipbar"
    private static let account = "db-key-v1"

    private static var cached: SymmetricKey?

    static func key() throws -> SymmetricKey {
        if let cached { return cached }
        let key = try loadKey() ?? createKey()
        cached = key
        return key
    }

    /// Diagnostics run from a terminal, which may not inherit the app's
    /// Keychain identity. The self-test uses a process-local key so it can test
    /// encryption without reading or creating production credentials.
    static func useEphemeralKeyForSelfTest() {
        cached = SymmetricKey(size: .bits256)
    }

    // MARK: - Sealing

    static func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key())
        guard let combined = box.combined else { throw Failure.corrupted }
        return combined
    }

    static func seal(_ string: String) throws -> Data {
        try seal(Data(string.utf8))
    }

    static func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key())
    }

    static func openString(_ data: Data) throws -> String {
        guard let string = String(data: try open(data), encoding: .utf8) else {
            throw Failure.corrupted
        }
        return string
    }

    /// Dedupe fingerprint. Keyed rather than a plain SHA-256 so the database
    /// can't be used to confirm a guess at an item's contents.
    static func fingerprint(_ data: Data) throws -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: try key())
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain

    private static func loadKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw Failure.corrupted }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    private static func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Available once the Mac has been unlocked after boot, and never
            // synced to iCloud — this key must not leave the machine.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }
}
