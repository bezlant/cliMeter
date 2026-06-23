import XCTest
@testable import Climeter

final class ClaudeCodeSyncServiceTests: XCTestCase {
    func test_credentialFromRawParses() {
        let raw = #"{"claudeAiOauth":{"accessToken":"kc","refreshToken":"r","expiresAt":1700000000000}}"#
        XCTAssertEqual(ClaudeCodeSyncService.credential(fromRaw: raw)?.accessToken, "kc")
    }

    func test_credentialFromRawNilForGarbage() {
        XCTAssertNil(ClaudeCodeSyncService.credential(fromRaw: "nope"))
    }
}
