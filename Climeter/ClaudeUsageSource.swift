import Foundation

enum ClaudeUsageSource: String, Codable, CaseIterable, Identifiable {
    case statusLineFile
    case keychainManual

    var id: String { rawValue }
}

struct ProfileManagerDependencies {
    var readCLICredential: (Bool) -> Credential?
    var keychainItemExists: () -> Bool
    var readMigrationCredential: (UUID) -> Credential?
    var moveLegacyCredentialFile: (URL, URL) -> Void
    var makeStatusLineStore: () -> ClaudeStatusLineUsageStore
    var powerMonitor: any PowerStateMonitoring
    var scheduleCLIDetection: (@escaping () -> Void) -> () -> Void
    var performCredentialWork: (@escaping () -> Void) -> () -> Void

    static var live: ProfileManagerDependencies {
        ProfileManagerDependencies(
            readCLICredential: {
                ClaudeCodeSyncService.readCLICredential(interactive: $0)
            },
            keychainItemExists: {
                ClaudeCodeSyncService.keychainItemExists()
            },
            readMigrationCredential: {
                ProfileManager.readOnlyMigrationCredential(for: $0)
            },
            moveLegacyCredentialFile: { source, destination in
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try? FileManager.default.moveItem(at: source, to: destination)
            },
            makeStatusLineStore: {
                ClaudeStatusLineUsageStore()
            },
            powerMonitor: PowerStateMonitor(),
            scheduleCLIDetection: { operation in
                let workItem = DispatchWorkItem(block: operation)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 2,
                    execute: workItem
                )
                return workItem.cancel
            },
            performCredentialWork: { operation in
                let workItem = DispatchWorkItem(block: operation)
                DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
                return workItem.cancel
            }
        )
    }
}
