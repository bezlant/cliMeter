import XCTest
@testable import Climeter

final class CredentialExpiryTests: XCTestCase {
    private func cred(_ millis: Double) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(millis)}}"#)!
    }

    func test_notExpiredFarFuture() {
        XCTAssertFalse(cred(9_000_000 * 1000).isExpired(now: Date(timeIntervalSince1970: 1000)))
    }

    func test_expiredWithinFiveMinuteMargin() {
        // expires 4 min after now -> expired (5-min safety margin)
        XCTAssertTrue(cred((1000 + 240) * 1000).isExpired(now: Date(timeIntervalSince1970: 1000)))
    }

    func test_equalityIncludesAccountUUID() {
        let a = Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":1000,"accountUUID":"A"}}"#)!
        let b = Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"x","refreshToken":"r","expiresAt":1000,"accountUUID":"B"}}"#)!
        XCTAssertNotEqual(a, b)
    }
}
