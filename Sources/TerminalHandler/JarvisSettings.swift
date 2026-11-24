import AppKit
import Synchronization
import THCore

/// Jarvis endpoint settings, all in the app's user defaults:
/// `jarvisPort` (default 8765), `jarvisAPIKey` (generated on first launch)
/// and `jarvisRequireKey` (default true). The phone's routes:
/// `jarvisRemoteEnabled` (default true) and `jarvisRemoteHosts` (extra
/// Host names besides `*.ts.net`).
nonisolated enum JarvisSettings {
    private static let listeningFlag = Mutex(false)

    static var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: "jarvisPort")
        return (1...65535).contains(value) ? UInt16(value) : JarvisAPI.defaultPort
    }

    static var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// The key FluidVoice must send as `Authorization: Bearer …`.
    static var apiKey: String {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: "jarvisAPIKey"), !key.isEmpty { return key }
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = "th-jarvis-" + bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(key, forKey: "jarvisAPIKey")
        return key
    }

    /// nil when the key check is turned off.
    static var requiredKey: String? {
        let defaults = UserDefaults.standard
        let required = defaults.object(forKey: "jarvisRequireKey") as? Bool ?? true
        return required ? apiKey : nil
    }

    /// The phone's routes always need the key, whatever `jarvisRequireKey` says.
    /// nil turns them off.
    static var remoteKey: String? {
        let enabled = UserDefaults.standard.object(forKey: "jarvisRemoteEnabled") as? Bool ?? true
        return enabled ? apiKey : nil
    }

    static var remoteHosts: [String] {
        UserDefaults.standard.stringArray(forKey: "jarvisRemoteHosts") ?? []
    }

    static var listening: Bool {
        get { listeningFlag.withLock { $0 } }
        set { listeningFlag.withLock { $0 = newValue } }
    }

    @MainActor static func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiKey, forType: .string)
    }

    @MainActor static func copyBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL, forType: .string)
    }
}
