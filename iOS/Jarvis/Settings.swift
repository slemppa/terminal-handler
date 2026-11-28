import Foundation
import Security

/// The Mac's Tailscale address in user defaults, the API key in the Keychain.
enum Settings {
    static var address: String {
        get { UserDefaults.standard.string(forKey: "address") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "address") }
    }

    static var apiKey: String {
        get { Keychain.read("apiKey") ?? "" }
        set { Keychain.write("apiKey", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var client: RemoteClient? {
        guard let url = URL(string: address), url.scheme != nil, !apiKey.isEmpty else { return nil }
        return RemoteClient(baseURL: url, apiKey: apiKey)
    }
}

enum Keychain {
    private static let service = "fi.slemppa.jarvis"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
