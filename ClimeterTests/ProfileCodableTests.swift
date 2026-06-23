import XCTest
@testable import Climeter

final class ProfileCodableTests: XCTestCase {
    func test_defaultSourceIsCLISynced() {
        XCTAssertEqual(Profile(name: "X").credentialSource, .cliSynced)
    }

    func test_legacyProfileWithoutSourceDefaultsToCLISynced() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: legacy).credentialSource, .cliSynced)
    }

    func test_roundTripPreservesSelfOwned() throws {
        var p = Profile(name: "Manual"); p.credentialSource = .selfOwned
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.credentialSource, .selfOwned)
    }
}
