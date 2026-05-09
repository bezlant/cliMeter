import XCTest
@testable import Climeter

final class ProfileManagerMigrationTests: XCTestCase {
    private enum TestError: Error {
        case writeFailed
    }

    func test_migratingToFileBasedSkipsKeychainDeletion() {
        let successfulID = UUID()
        let failedID = UUID()
        let cached = [
            successfulID: Self.credential(accessToken: "ok"),
            failedID: Self.credential(accessToken: "fail")
        ]
        var deletedFromKeychain: Set<UUID> = []
        var loggedFailures: [UUID] = []

        ProfileManager.migrateCredentialStorage(
            toFileBased: true,
            cachedCredentials: cached,
            saveStorageMode: { _ in },
            saveCredential: { _, profileID in
                if profileID == failedID { throw TestError.writeFailed }
            },
            deleteKeychainCredential: { profileID in
                deletedFromKeychain.insert(profileID)
            },
            deleteFileCredentials: {},
            logSaveFailure: { profileID, _ in
                loggedFailures.append(profileID)
            }
        )

        XCTAssertTrue(deletedFromKeychain.isEmpty)
        XCTAssertEqual(loggedFailures, [failedID])
    }

    func test_migratingToKeychainDeletesFileStoreOnlyWhenAllProfilesSave() {
        let successfulID = UUID()
        let failedID = UUID()
        let cached = [
            successfulID: Self.credential(accessToken: "ok"),
            failedID: Self.credential(accessToken: "fail")
        ]
        var didDeleteFileStore = false

        ProfileManager.migrateCredentialStorage(
            toFileBased: false,
            cachedCredentials: cached,
            saveStorageMode: { _ in },
            saveCredential: { _, profileID in
                if profileID == failedID { throw TestError.writeFailed }
            },
            deleteKeychainCredential: { _ in },
            deleteFileCredentials: {
                didDeleteFileStore = true
            },
            logSaveFailure: { _, _ in }
        )

        XCTAssertFalse(didDeleteFileStore)
    }

    func test_migratingToKeychainDeletesFileStoreWhenAllProfilesSave() {
        let cached = [
            UUID(): Self.credential(accessToken: "a"),
            UUID(): Self.credential(accessToken: "b")
        ]
        var didDeleteFileStore = false

        ProfileManager.migrateCredentialStorage(
            toFileBased: false,
            cachedCredentials: cached,
            saveStorageMode: { _ in },
            saveCredential: { _, _ in },
            deleteKeychainCredential: { _ in },
            deleteFileCredentials: {
                didDeleteFileStore = true
            },
            logSaveFailure: { _, _ in }
        )

        XCTAssertTrue(didDeleteFileStore)
    }

    private static func credential(accessToken: String) -> Credential {
        Credential(jsonString: """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"refresh","expiresAt":1700000000000}}
        """)!
    }
}
