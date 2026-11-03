import Foundation
import Security

/// What the Discord web client identified itself as when it signed in: the
/// token plus the exact super-properties header and user agent it sent, so
/// REST and gateway traffic look like that same client.
nonisolated struct SessionCredentials: Codable, Equatable, Sendable {
    var token: String
    /// Base64 X-Super-Properties captured from the login page.
    var superProperties: String?
    var userAgent: String

    static let desktopSafariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Decoded super properties, used to build gateway identify properties.
    var properties: [String: JSONValue] {
        if let superProperties, let data = Data(base64Encoded: superProperties),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return decoded
        }
        return [
            "os": .string("Mac OS X"),
            "browser": .string("Safari"),
            "device": .string(""),
            "system_locale": .string(Locale.preferredLanguages.first ?? "en-US"),
            "browser_user_agent": .string(userAgent),
            "browser_version": .string("26.0"),
            "os_version": .string("10.15.7"),
            "referrer": .string(""),
            "referring_domain": .string(""),
            "release_channel": .string("stable"),
            "client_build_number": .number(470_000),
            "client_event_source": .null,
        ]
    }

    /// The header value: the captured one, else an encoding of `properties`.
    var superPropertiesHeader: String {
        if let superProperties { return superProperties }
        let data = (try? JSONEncoder().encode(properties)) ?? Data()
        return data.base64EncodedString()
    }
}

/// Generic-password Keychain storage, this device only.
nonisolated enum Keychain {
    static func load(service: String, account: String = "primary") -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Updates in place, so a failure never leaves the item missing.
    @discardableResult
    static func save(_ data: Data, service: String, account: String = "primary") -> Bool {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String = "primary") {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

nonisolated enum SessionStore {
    private static let service = "com.saphid.duocord.native.session"

    static func load() -> SessionCredentials? {
        Keychain.load(service: service).flatMap { try? JSONDecoder().decode(SessionCredentials.self, from: $0) }
    }

    @discardableResult
    static func save(_ credentials: SessionCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return Keychain.save(data, service: service)
    }

    static func clear() { Keychain.delete(service: service) }
}

/// Optional saved email/password, only used to pre-fill Discord's own login
/// form. Arrives once via a provisioning file (from 1Password through
/// op-agent) that is moved into the Keychain and deleted.
nonisolated struct LoginCredentials: Codable, Equatable, Sendable {
    var email: String
    var password: String
}

nonisolated enum LoginStore {
    private static let service = "com.saphid.duocord.native.login"

    static func load() -> LoginCredentials? {
        Keychain.load(service: service).flatMap { try? JSONDecoder().decode(LoginCredentials.self, from: $0) }
    }

    static func clear() { Keychain.delete(service: service) }

    /// Imports Documents/duocord-provision.json (`{"email","password"}`), then deletes it.
    /// The file can only be placed by the owner's developer tools
    /// (`devicectl ... copy to --domain-type appDataContainer`), so it may also
    /// carry the owner's one-time consent to sign in automatically.
    struct Provision: Decodable {
        var email: String
        var password: String
        /// The owner has read the account-risk notice (`scripts/install-device.sh`).
        var acknowledgeRisk: Bool?
    }

    /// One-shot: sign in automatically with the provisioned login on next launch.
    static let autoSignInKey = "DuocordProvisionedAutoSignIn"

    /// Returns the provision when a file was imported this launch.
    @discardableResult
    static func importProvisioningFile() -> Provision? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = docs.appending(path: "duocord-provision.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? fm.removeItem(at: url) }
        guard let provision = try? JSONDecoder().decode(Provision.self, from: data),
              !provision.email.isEmpty, !provision.password.isEmpty,
              let encoded = try? JSONEncoder().encode(LoginCredentials(email: provision.email, password: provision.password))
        else { return nil }
        guard Keychain.save(encoded, service: service) else { return nil }
        UserDefaults.standard.set(true, forKey: autoSignInKey)
        return provision
    }
}
