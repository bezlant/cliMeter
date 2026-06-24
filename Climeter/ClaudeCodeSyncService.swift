import Foundation
import Security

enum ClaudeCodeSyncService {
    private static let serviceName = "Claude Code-credentials"
    private static let account = NSUserName()

    static func credential(fromRaw raw: String) -> Credential? {
        let c = Credential(jsonString: raw)
        if c == nil {
            Log.cliSync.warning("Keychain data parsed-fail as Credential")
        }
        return c
    }

    /// Read-only. interactive=false uses kSecUseAuthenticationUIFail (never prompts).
    static func readCLICredential(interactive: Bool) -> Credential? {
        guard let raw = readCLICredentialRaw(interactive: interactive) else { return nil }
        return credential(fromRaw: raw)
    }

    static func readCLICredentialRaw(interactive: Bool) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        Log.cliSync.info("readCLICredential(interactive=\(interactive)): \(Log.keychainStatus(status))")

        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// True iff the Keychain item exists & is readable (used to guard file backup).
    static func keychainItemExists() -> Bool {
        readCLICredential(interactive: false) != nil
    }
}
