import Foundation
import Security

struct SubtitleAIConfiguration: Equatable, Sendable {
    var baseURL: String
    var model: String
    var apiKey: String

    init(baseURL: String = "", model: String = "", apiKey: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// A base URL can end in /v1 (or another service prefix), or name the
    /// complete chat/completions endpoint. Secrets never belong in the URL.
    func endpoint() throws -> URL {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !modelName.isEmpty,
              !modelName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SubtitleAIError.invalidConfiguration }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") {
            path += path.isEmpty ? "/v1/chat/completions" : "/chat/completions"
        }
        components.path = path
        guard let url = components.url else { throw SubtitleAIError.invalidConfiguration }
        return url
    }
}

protocol SubtitleAPIKeyStore: Sendable {
    func read() throws -> String
    func write(_ value: String) throws
}

struct SubtitleKeychainStore: SubtitleAPIKeyStore {
    let service: String
    private let account = "subtitle-ai-api-key"

    init(service: String = (Bundle.main.bundleIdentifier ?? "cn.laogou.dogsc") + ".subtitle-ai") {
        self.service = service
    }

    func read() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw SubtitleAIError.keychainUnavailable }
        return value
    }

    func write(_ value: String) throws {
        let query = baseQuery
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound
            else { throw SubtitleAIError.keychainUnavailable }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SubtitleAIError.keychainUnavailable }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

@MainActor
enum SubtitleAISettings {
    private static let addressKey = "subtitleAI.baseURL"
    private static let modelKey = "subtitleAI.model"

    static func load(
        defaults: UserDefaults = .standard,
        keyStore: any SubtitleAPIKeyStore = SubtitleKeychainStore()
    ) throws -> SubtitleAIConfiguration {
        SubtitleAIConfiguration(baseURL: defaults.string(forKey: addressKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "", apiKey: try keyStore.read())
    }

    static func save(
        _ configuration: SubtitleAIConfiguration,
        defaults: UserDefaults = .standard,
        keyStore: any SubtitleAPIKeyStore = SubtitleKeychainStore()
    ) throws {
        _ = try configuration.endpoint()
        try keyStore.write(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey)
        defaults.set(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey)
    }
}
