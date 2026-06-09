import Foundation
import Security

struct SharedKeychain {
    private static let accessGroupSuffix = "com.clawmate.shared"

    private static let accessGroup: String = {
        // Probe the keychain to discover the team identifier prefix at runtime,
        // so the source tree contains no hard-coded Apple Team ID.
        let probeService = "__clawmate_widget_access_group_probe__"
        let probeAccount = "probe"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount,
                kSecValueData as String: Data(),
            ]
            SecItemAdd(add as CFDictionary, nil)
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecSuccess,
           let attrs = result as? [String: Any],
           let fullGroup = attrs[kSecAttrAccessGroup as String] as? String,
           let prefix = fullGroup.split(separator: ".").first {
            return "\(prefix).\(accessGroupSuffix)"
        }
        return accessGroupSuffix
    }()

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func readJSON<T: Decodable>(key: String, as type: T.Type) -> T? {
        guard let str = read(key: key),
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
