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
