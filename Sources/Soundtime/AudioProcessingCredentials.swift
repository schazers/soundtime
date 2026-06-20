import Foundation
import Security

enum AudioProcessingCredentials {
    private static let audioShakeEnvironmentKey = "SOUNDTIME_AUDIOSHAKE_API_KEY"
    private static let audioShakeKeychainService = "com.soundtime.audioshake"
    private static let audioShakeKeychainAccount = "api-key"

    enum CredentialError: LocalizedError {
        case keychainReadFailed(OSStatus)
        case keychainWriteFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .keychainReadFailed(status):
                "Could not read the AudioShake API key from Keychain (\(status))."
            case let .keychainWriteFailed(status):
                "Could not save the AudioShake API key to Keychain (\(status))."
            case let .keychainDeleteFailed(status):
                "Could not remove the AudioShake API key from Keychain (\(status))."
            }
        }
    }

    static func audioShakeAPIKey() -> String? {
        if let environmentKey = normalizedAPIKey(ProcessInfo.processInfo.environment[audioShakeEnvironmentKey]) {
            return environmentKey
        }

        return try? storedAudioShakeAPIKey()
    }

    static func storedAudioShakeAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: audioShakeKeychainService,
            kSecAttrAccount as String: audioShakeKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialError.keychainReadFailed(status)
        }
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return normalizedAPIKey(value)
    }

    static func setStoredAudioShakeAPIKey(_ apiKey: String?) throws {
        guard let normalizedKey = normalizedAPIKey(apiKey) else {
            try deleteStoredAudioShakeAPIKey()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: audioShakeKeychainService,
            kSecAttrAccount as String: audioShakeKeychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalizedKey.utf8),
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = Data(normalizedKey.utf8)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialError.keychainWriteFailed(addStatus)
        }
    }

    static func deleteStoredAudioShakeAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: audioShakeKeychainService,
            kSecAttrAccount as String: audioShakeKeychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychainDeleteFailed(status)
        }
    }

    private static func normalizedAPIKey(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
