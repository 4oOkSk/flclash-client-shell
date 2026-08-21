import Cocoa
import FlutterMacOS
import window_manager
import LaunchAtLogin
import Security

private enum ClientSecureStorage {
    static let service = "com.example.harborproxy.client-cache-key"
    static let account = "client-cache-master-key-v2"

    static func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement ||
            status == errSecInteractionNotAllowed ||
            status == errSecNotAvailable
    }

    static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound && !isUnavailable(status) {
                NSLog("HarborProxy secure storage read failed status=%d", status)
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            NSLog("HarborProxy secure storage update failed status=%d", updateStatus)
            return false
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && !isUnavailable(addStatus) {
            NSLog("HarborProxy secure storage add failed status=%d", addStatus)
        }
        return addStatus == errSecSuccess
    }

    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound ||
            isUnavailable(status)
    }
}

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        
        FlutterMethodChannel(
            name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any] {
                    LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        FlutterMethodChannel(
            name: "com.follow.clash/client_secure_storage",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { call, result in
            switch call.method {
            case "read":
                result(ClientSecureStorage.read())
            case "write":
                guard let arguments = call.arguments as? [String: Any],
                      let value = arguments["value"] as? String else {
                    result(FlutterError(code: "invalid_value", message: "secure storage value missing", details: nil))
                    return
                }
                result(ClientSecureStorage.write(value))
            case "delete":
                result(ClientSecureStorage.delete())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        RegisterGeneratedPlugins(registry: flutterViewController)
        super.awakeFromNib()
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}
