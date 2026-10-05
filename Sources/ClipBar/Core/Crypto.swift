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
        /// The Keychain has no key but the database already holds sealed rows.
        case keyMissing
    }

    /// Set by `Store` once it knows whether the database is empty.
    ///
    /// Minting a key over a database that already has rows is the one
    /// irreversible thing this file could do: every existing row stops
    /// decrypting, `Store.query` skips them, and the history and every folder
    /// look empty with no error anywhere. A Keychain reset or migration (an OS
    /// upgrade is the likely trigger) answers "not found" exactly like a first
    /// launch does, so "not found" alone is not enough to create one. Starts
    /// false so nothing creates a key before a store has vouched for it.
    static var allowsKeyCreation: Bool {
        get { lock.lock(); defer { lock.unlock() }; return creationAllowed }
        set { lock.lock(); defer { lock.unlock() }; creationAllowed = newValue }
    }
    private static var creationAllowed = false

    private static let service = "io.local.clipbar"

    /// Where the key lives now, and where it used to live. See `loadKey` for why
    /// it moved and why the old entry is left behind rather than deleted.
    private static let account = "db-key-v2"
    private static let legacyAccount = "db-key-v1"

    private static var cached: SymmetricKey?

    /// The cache is read from the main thread and filled from a background one
    /// during warm-up, so it needs a lock. Contention is a non-issue: it is held
    /// for a dictionary read after the first call.
    private static let lock = NSLock()

    static func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let key = try loadKey() ?? (creationAllowed ? createKey() : nil) else {
            Log.store.fault("database key not found in the Keychain and the database is not empty")
            throw Failure.keyMissing
        }
        cached = key
        return key
    }


    /// Diagnostics run from a terminal, which may not inherit the app's
    /// Keychain identity. The self-test uses a process-local key so it can test
    /// encryption without reading or creating production credentials.
    static func useEphemeralKeyForSelfTest() {
        lock.lock()
        defer { lock.unlock() }
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

    /// True while the key still lives only under the old account.
    ///
    /// Asks for attributes and not data, which is what keeps it from raising the
    /// very dialog the migration exists to get rid of.
    static var needsKeyMigration: Bool {
        isAbsent(account: account)
    }

    /// True when neither account holds a key and the store says the database
    /// is not empty — the state `key()` refuses to paper over. Attribute-only
    /// queries, so it is safe to ask on the main thread at launch.
    static var keyIsMissing: Bool {
        !allowsKeyCreation && isAbsent(account: account) && isAbsent(account: legacyAccount)
    }

    private static func isAbsent(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
    }

    /// Reads the key, re-filing it under the current account the first time.
    ///
    /// The old entry was created by an ad-hoc signed build, before this app had
    /// a stable signing certificate. A Keychain item's ACL records the
    /// *designated requirement* of whichever app created it, and an ad-hoc
    /// requirement is the code hash — which changed on the next compile, and on
    /// every compile since. So every launch, reading the key raised an
    /// authorization dialog: `SecurityAgent` spawned with `bringForward=0`, sat
    /// invisible behind the windows, and the app waited on it. Nine seconds on a
    /// good run, a minute when nobody stumbled into answering it. That wait, on
    /// the first ⌘⌥V after a launch, is the whole of "the shortcut opens the bar
    /// sometimes".
    ///
    /// Re-adding the same key under a new account rebuilds the ACL around the
    /// certificate-based requirement, which is exactly the one designed to
    /// survive rebuilds. The old entry is deliberately left alone: it costs one
    /// Keychain row, and until the new one is proven it is the only copy of the
    /// key that can read this database.
    private static func loadKey() throws -> SymmetricKey? {
        if let current = try loadKey(account: account) { return current }

        guard let legacy = try loadKey(account: legacyAccount) else { return nil }
        do {
            try store(legacy, account: account)
            Log.store.notice("database key re-filed under \(account, privacy: .public)")
        } catch {
            // Not fatal — we have the key, and the worst case is being asked
            // again on the next launch, which is where we already were.
            Log.store.error("could not re-file the database key: \(String(describing: error), privacy: .public)")
        }
        return legacy
    }

    private static func loadKey(account: String) throws -> SymmetricKey? {
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
        try store(key, account: account)
        return key
    }

    private static func store(_ key: SymmetricKey, account: String) throws {
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
    }
}
