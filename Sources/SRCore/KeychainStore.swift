import Foundation
import Security

/// Keychain-only credential storage (P-1).
///
/// The ElevenLabs API key lives in the login keychain as a generic
/// password, service "sr — ElevenLabs API Key", account "elevenlabs" —
/// the same attributes the `security` CLI writes, so keys added with
/// `security add-generic-password -a elevenlabs -s "sr — ElevenLabs API Key"`
/// are found here. No config file, no environment variable override.
public enum KeychainStore {
    public static let service = "sr — ElevenLabs API Key"
    public static let account = "elevenlabs"

    public static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// Saving replaces the item instead of updating it in place.
    ///
    /// A keychain item's ACL is fixed when the item is created, and names the
    /// app that created it. An item written by an earlier ad-hoc build — whose
    /// code identity was the binary's own hash, and so different every build —
    /// or by `security add-generic-password`, names an app this one is not, and
    /// macOS answers that with a password prompt on every single read. Writing
    /// the item afresh puts the running app in the ACL, so one "Always Allow"
    /// holds for good (the app's identity is stable now: see
    /// `scripts/setup-signing.sh`).
    ///
    /// Delete-then-add is safe in that order. If the delete is refused the old
    /// item survives untouched and the save reports failure, so a key is never
    /// lost to a half-completed replacement.
    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deletion = SecItemDelete(base as CFDictionary)
        guard deletion == errSecSuccess || deletion == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Masked display form: last 4 characters only (P-1).
    public static func maskedAPIKey() -> String? {
        guard let key = readAPIKey() else { return nil }
        return "••••••••" + key.suffix(4)
    }
}
