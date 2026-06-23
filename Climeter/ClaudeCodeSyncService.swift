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

    @available(*, deprecated, message: "Use readCLICredential(interactive:) for read-only Keychain access.")
    static func readCLICredential(preferFile: Bool = false) -> Credential? {
        if let fileCred = readCLICredentialFromFile() {
            return fileCred
        }
        guard let raw = readCLICredentialRaw(interactive: true) else { return nil }
        let credential = Credential(jsonString: raw)
        if credential == nil {
            Log.cliSync.warning("CLI keychain data read OK but failed to parse as Credential")
        }
        if preferFile, credential != nil, !cliCredentialFileExists() {
            Log.cliSync.info("Bootstrapping credential file from keychain (raw)")
            writeRawToCredentialFile(raw)
        }
        return credential
    }

    @available(*, deprecated, message: "File credential probing is obsolete for Claude Code sync.")
    static func cliCredentialFileExists(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        let candidates = [
            claudeDir.appendingPathComponent(".credentials.json"),
            claudeDir.appendingPathComponent("credentials.json")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    @available(*, deprecated, message: "File credential reads are obsolete for Claude Code sync.")
    static func readCLICredentialFromFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Credential? {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        let candidates = [
            claudeDir.appendingPathComponent(".credentials.json"),
            claudeDir.appendingPathComponent("credentials.json")
        ]

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let str = String(data: data, encoding: .utf8) else {
                continue
            }
            if let cred = Credential(jsonString: str) {
                Log.cliSync.info("readCLICredentialFromFile: success from \(path.lastPathComponent)")
                return cred
            }
        }
        return nil
    }

    @available(*, deprecated, message: "Use readCLICredentialRaw(interactive:) for read-only Keychain access.")
    static func readCLICredentialRaw() -> String? {
        readCLICredentialRaw(interactive: true)
    }

    @available(*, deprecated, message: "Claude Code credentials are read-only; avoid writing via sync service.")
    static func writeCLICredential(_ credential: Credential, preferFile: Bool = false) {
        if preferFile {
            writeCLICredentialToFile(credential)
        } else {
            writeCLICredentialToKeychain(credential)
        }
    }

    private static func writeCLICredentialToFile(_ credential: Credential) {
        writeRawToCredentialFile(credential.toJSONString())
    }

    private static func writeRawToCredentialFile(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let credFile = claudeDir.appendingPathComponent(".credentials.json")

        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

            let tmpFile = claudeDir.appendingPathComponent(".credentials.tmp")
            fm.createFile(atPath: tmpFile.path, contents: data,
                          attributes: [.posixPermissions: 0o600])
            try fm.replaceItemAt(credFile, withItemAt: tmpFile,
                                 backupItemName: nil, options: .usingNewMetadataOnly)

            Log.cliSync.info("writeCLICredentialToFile: success")
        } catch {
            Log.cliSync.error("writeCLICredentialToFile failed: \(error)")
        }
    }

    private static func writeCLICredentialToKeychain(_ credential: Credential) {
        let jsonString = credential.toJSONString()
        guard let data = jsonString.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        // Try updating in-place first to preserve existing ACL (including
        // any "Always Allow" grants the user has given to Claude Code CLI).
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        Log.cliSync.info("writeCLICredential SecItemUpdate: \(Log.keychainStatus(updateStatus))")

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — create with an ACL that trusts
            // both Climeter and /usr/bin/security.
            var addQuery = query
            addQuery[kSecValueData as String] = data

            if let access = makeSharedAccess() {
                addQuery[kSecAttrAccess as String] = access
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            Log.cliSync.info("writeCLICredential SecItemAdd: \(Log.keychainStatus(addStatus))")
        } else if updateStatus != errSecSuccess {
            Log.cliSync.error("writeCLICredential update failed: \(Log.keychainStatus(updateStatus))")
        }
    }

    private static func makeSharedAccess() -> SecAccess? {
        var trustedApps: [SecTrustedApplication] = []

        var selfApp: SecTrustedApplication?
        SecTrustedApplicationCreateFromPath(nil, &selfApp)
        if let selfApp { trustedApps.append(selfApp) }

        var securityTool: SecTrustedApplication?
        SecTrustedApplicationCreateFromPath("/usr/bin/security", &securityTool)
        if let securityTool { trustedApps.append(securityTool) }

        var access: SecAccess?
        SecAccessCreate(serviceName as CFString, trustedApps as CFArray, &access)
        return access
    }
}
