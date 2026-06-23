import XCTest
@testable import Climeter

final class ClimeterTests: XCTestCase {
    func test_testTargetIsWired() {
        XCTAssertEqual(UsageWindow(utilization: 12, resetsAt: nil).utilization, 12)
    }

    func test_profileManagerCredentialSourceWiring() {
        XCTAssertTrue(ProfileManager.usesReadOnlyCoordinator(for: .cliSynced))
        XCTAssertFalse(ProfileManager.shouldPersistSecret(for: .cliSynced))

        XCTAssertFalse(ProfileManager.usesReadOnlyCoordinator(for: .selfOwned))
        XCTAssertTrue(ProfileManager.shouldPersistSecret(for: .selfOwned))
    }

    func test_profileCardStaleWaitingMessageUsesCoordinatorFlagOrTenMinuteAge() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(ClaudeStalePresentation.waitingMessage(
            credentialSource: .cliSynced,
            isStale: false,
            lastSuccessAt: now.addingTimeInterval(-599),
            currentTime: now
        ))
        XCTAssertEqual(
            ClaudeStalePresentation.waitingMessage(
                credentialSource: .cliSynced,
                isStale: false,
                lastSuccessAt: now.addingTimeInterval(-601),
                currentTime: now
            ),
            "Updated 10m ago — waiting for Claude Code"
        )
        XCTAssertEqual(
            ClaudeStalePresentation.waitingMessage(
                credentialSource: .cliSynced,
                isStale: true,
                lastSuccessAt: now.addingTimeInterval(-60),
                currentTime: now
            ),
            "Updated 1m ago — waiting for Claude Code"
        )
        XCTAssertEqual(
            ClaudeStalePresentation.waitingMessage(
                credentialSource: .cliSynced,
                isStale: true,
                lastSuccessAt: nil,
                currentTime: now
            ),
            "Waiting for Claude Code"
        )
        XCTAssertNil(ClaudeStalePresentation.waitingMessage(
            credentialSource: .selfOwned,
            isStale: true,
            lastSuccessAt: now.addingTimeInterval(-601),
            currentTime: now
        ))
    }
}
