import XCTest
@testable import Climeter

final class CLICredentialPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func cred(_ secsFromNow: Double, _ token: String) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":\#((10_000 + secsFromNow) * 1000)}}"#)!
    }

    func test_cachedValid_fetchesCached() {
        let c = cred(3600, "cached")
        XCTAssertEqual(CLICredentialPolicy.action(cached: c, keychain: nil, now: now), .fetchUsage(c))
    }

    func test_cachedExpired_noKeychainYet_rereads() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: nil, now: now), .rereadKeychain)
    }

    func test_cachedExpired_keychainFresh_fetchAndCache() {
        let fresh = cred(3600, "fresh")
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: fresh, now: now), .fetchUsageAndCache(fresh))
    }

    func test_bothExpired_stale() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: cred(60, "old"), keychain: cred(60, "old2"), now: now), .showStale)
    }

    func test_noCached_keychainFresh_fetchAndCache() {
        let fresh = cred(3600, "fresh")
        XCTAssertEqual(CLICredentialPolicy.action(cached: nil, keychain: fresh, now: now), .fetchUsageAndCache(fresh))
    }

    func test_noCached_noKeychain_rereads() {
        XCTAssertEqual(CLICredentialPolicy.action(cached: nil, keychain: nil, now: now), .rereadKeychain)
    }
}
