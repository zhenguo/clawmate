import Flutter
import WidgetKit

class WidgetDataBridge: NSObject, FlutterPlugin {
    private static let accessGroupSuffix = "com.clawmate.shared"

    private static let accessGroup: String = {
        // Probe the keychain to discover the team identifier prefix at runtime,
        // so the source tree contains no hard-coded Apple Team ID.
        let probeService = "__clawmate_access_group_probe__"
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

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.clawmate.widget_bridge",
            binaryMessenger: registrar.messenger()
        )
        let instance = WidgetDataBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "saveWidgetData":
            guard let args = call.arguments as? [String: String],
                  let key = args["key"],
                  let value = args["value"] else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            let success = WidgetDataBridge.keychainWrite(key: key, value: value)
            if #available(iOS 14.0, *) {
                WidgetCenter.shared.reloadAllTimelines()
            }
            result(success)
        case "getWidgetData":
            guard let args = call.arguments as? [String: String],
                  let key = args["key"] else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            result(WidgetDataBridge.keychainRead(key: key))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func keychainWrite(key: String, value: String) -> Bool {
        let data = value.data(using: .utf8)!

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func keychainRead(key: String) -> String? {
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
}
