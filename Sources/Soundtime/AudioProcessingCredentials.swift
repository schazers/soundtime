import Foundation
import Security

enum AudioProcessingCredentials {
    private static let audioShakeEnvironmentKey = "SOUNDTIME_AUDIOSHAKE_API_KEY"
    private static let audioShakeKeychainService = "com.soundtime.audioshake"
    private static let audioShakeKeychainAccount = "api-key"
    private static let deepgramEnvironmentKey = "DEEPGRAM_API_KEY"
    private static let deepgramKeychainService = "com.soundtime.deepgram"
    private static let deepgramKeychainAccount = "api-key"

    enum CredentialError: LocalizedError {
        case keychainReadFailed(OSStatus)
        case keychainWriteFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .keychainReadFailed(status):
                "Could not read the API key from Keychain (\(status))."
            case let .keychainWriteFailed(status):
                "Could not save the API key to Keychain (\(status))."
            case let .keychainDeleteFailed(status):
                "Could not remove the API key from Keychain (\(status))."
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
        try storedAPIKey(
            service: audioShakeKeychainService,
            account: audioShakeKeychainAccount
        )
    }

    static func setStoredAudioShakeAPIKey(_ apiKey: String?) throws {
        try setStoredAPIKey(
            apiKey,
            service: audioShakeKeychainService,
            account: audioShakeKeychainAccount
        )
    }

    static func deleteStoredAudioShakeAPIKey() throws {
        try deleteStoredAPIKey(
            service: audioShakeKeychainService,
            account: audioShakeKeychainAccount
        )
    }

    static func deepgramAPIKey() -> String? {
        if let environmentKey = normalizedAPIKey(ProcessInfo.processInfo.environment[deepgramEnvironmentKey]) {
            return environmentKey
        }

        return try? storedDeepgramAPIKey()
    }

    static func storedDeepgramAPIKey() throws -> String? {
        try storedAPIKey(
            service: deepgramKeychainService,
            account: deepgramKeychainAccount
        )
    }

    static func setStoredDeepgramAPIKey(_ apiKey: String?) throws {
        try setStoredAPIKey(
            apiKey,
            service: deepgramKeychainService,
            account: deepgramKeychainAccount
        )
    }

    static func deleteStoredDeepgramAPIKey() throws {
        try deleteStoredAPIKey(
            service: deepgramKeychainService,
            account: deepgramKeychainAccount
        )
    }

    private static func storedAPIKey(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private static func setStoredAPIKey(_ apiKey: String?, service: String, account: String) throws {
        guard let normalizedKey = normalizedAPIKey(apiKey) else {
            try deleteStoredAPIKey(service: service, account: account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private static func deleteStoredAPIKey(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
