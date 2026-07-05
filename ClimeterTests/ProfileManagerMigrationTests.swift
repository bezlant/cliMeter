import XCTest
@testable import Climeter

final class ProfileManagerMigrationTests: XCTestCase {
    func test_migrationBacksUpFileOnlyWhenKeychainExists() {
        var moved: (URL, URL)?
        ProfileManager.backupStaleCredentialFile(
            keychainExists: true, fileURL: URL(fileURLWithPath: "/h/.claude/.credentials.json"),
            backupURL: URL(fileURLWithPath: "/h/.claude/.credentials.json.climeter-bak"),
            fileExists: { _ in true }, moveFile: { s, d in moved = (s, d) })
        XCTAssertEqual(moved?.1.lastPathComponent, ".credentials.json.climeter-bak")
    }

    func test_migrationLeavesFileWhenNoKeychain() {
        var moved = false
        ProfileManager.backupStaleCredentialFile(
            keychainExists: false, fileURL: URL(fileURLWithPath: "/h/x"), backupURL: URL(fileURLWithPath: "/h/y"),
            fileExists: { _ in true }, moveFile: { _, _ in moved = true })
        XCTAssertFalse(moved)
    }

    func test_profileMigrationStillRunsWhenLegacyFileBackupMigrationAlreadyRan() {
        let plan = ProfileManager.readOnlyMigrationPlan(
            legacyCredentialFileBackupDone: true,
            profileMigrationDone: false
        )

        XCTAssertTrue(plan.runProfileMigration)
        XCTAssertFalse(plan.runCredentialFileBackup)
    }

    func test_migrationMarksAllCliSyncedPreservesAuthAndSavesMetadataBeforePurge() {
        let withSecret = Profile(name: "S")
        let without = Profile(name: "N")
        var marked: [UUID] = []
        var purged: [UUID] = []
        var metadata: [(UUID, String)] = []
        let out = ProfileManager.migrateProfilesToReadOnly(
            profiles: [withSecret, without],
            storedCredential: { $0 == withSecret.id ? Self.credential(accessToken: "stored", accountUUID: "acct-1") : nil },
            saveMetadata: { metadata.append(($1, $0.accountUUID ?? "")) },
            purgeSecret: { purged.append($0) },
            markAuthenticated: { marked.append($0) })
        XCTAssertTrue(out.allSatisfy { $0.credentialSource == .cliSynced })
        XCTAssertEqual(marked, [withSecret.id])
        XCTAssertEqual(metadata.map { $0.0 }, [withSecret.id])
        XCTAssertEqual(metadata.map { $0.1 }, ["acct-1"])
        XCTAssertEqual(Set(purged), Set([withSecret.id, without.id]))
    }

    func test_readOnlyMigrationCredentialFallsBackToLegacyFileStore() {
        let id = UUID()
        let credential = ProfileManager.readOnlyMigrationCredential(
            for: id,
            keychainCredential: { _ in nil },
            fileCredentialRaw: { requestedID in
                requestedID == id ? Self.credential(accessToken: "file", accountUUID: "acct-file").toJSONString() : nil
            }
        )

        XCTAssertEqual(credential?.accessToken, "file")
        XCTAssertEqual(credential?.accountUUID, "acct-file")
    }

    func test_readOnlyMigrationCredentialPrefersKeychainOverLegacyFileStore() {
        let id = UUID()
        let credential = ProfileManager.readOnlyMigrationCredential(
            for: id,
            keychainCredential: { _ in Self.credential(accessToken: "keychain", accountUUID: "acct-keychain") },
            fileCredentialRaw: { _ in Self.credential(accessToken: "file", accountUUID: "acct-file").toJSONString() }
        )

        XCTAssertEqual(credential?.accessToken, "keychain")
        XCTAssertEqual(credential?.accountUUID, "acct-keychain")
    }

    func test_authenticationStateDoesNotLoadPersistedSecretsForCliSyncedProfiles() {
        let cliSynced = Profile(name: "CLI", credentialSource: .cliSynced)
        let selfOwned = Profile(name: "Manual", credentialSource: .selfOwned)
        var loaded: [UUID] = []

        let state = ProfileManager.computeAuthenticationState(
            profiles: [cliSynced, selfOwned],
            existingCredentials: [:],
            storedCredential: { id in
                loaded.append(id)
                return Self.credential(accessToken: "stored", accountUUID: "acct-\(id.uuidString)")
            },
            authenticatedMarkers: [cliSynced.id]
        )

        XCTAssertEqual(loaded, [selfOwned.id])
        XCTAssertNil(state.credentials[cliSynced.id])
        XCTAssertNotNil(state.credentials[selfOwned.id])
        XCTAssertEqual(state.authenticatedProfileIDs, Set([cliSynced.id, selfOwned.id]))
    }

    func test_profileMigrationCanRunWithoutBackingUpFile() {
        var moved = false
        var purged: [UUID] = []
        let selfOwned = Profile(name: "Future", credentialSource: .selfOwned)

        ProfileManager.backupStaleCredentialFile(
            keychainExists: false,
            fileURL: URL(fileURLWithPath: "/h/.claude/.credentials.json"),
            backupURL: URL(fileURLWithPath: "/h/.claude/.credentials.json.climeter-bak"),
            fileExists: { _ in true },
            moveFile: { _, _ in moved = true }
        )
        let out = ProfileManager.migrateProfilesToReadOnly(
            profiles: [selfOwned],
            storedCredential: { _ in nil },
            saveMetadata: { _, _ in },
            purgeSecret: { purged.append($0) },
            markAuthenticated: { _ in }
        )

        XCTAssertFalse(moved)
        XCTAssertEqual(out.first?.credentialSource, .cliSynced)
        XCTAssertEqual(purged, [selfOwned.id])
    }

    private static func credential(accessToken: String, accountUUID: String) -> Credential {
        Credential(jsonString: """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"refresh","expiresAt":1700000000000,"accountUUID":"\(accountUUID)"}}
        """)!
    }
}
