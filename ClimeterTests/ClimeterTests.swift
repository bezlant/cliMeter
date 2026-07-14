import AppKit
import SwiftUI
import XCTest
@testable import Climeter

private struct AccessibilitySnapshot {
    let role: NSAccessibility.Role?
    let label: String?
    let value: String?
    let identifier: String?
    let frame: NSRect
}

@MainActor
private func accessibilitySnapshots(from root: NSView) -> [AccessibilitySnapshot] {
    var snapshots: [AccessibilitySnapshot] = []
    var visited = Set<ObjectIdentifier>()

    func walk(_ element: any NSAccessibilityProtocol, depth: Int) {
        guard depth <= 12 else { return }
        let objectID = ObjectIdentifier(element as AnyObject)
        guard visited.insert(objectID).inserted else { return }

        snapshots.append(AccessibilitySnapshot(
            role: element.accessibilityRole(),
            label: element.accessibilityLabel(),
            value: element.accessibilityValue() as? String,
            identifier: element.accessibilityIdentifier(),
            frame: element.accessibilityFrame()
        ))

        for child in element.accessibilityChildren() ?? [] {
            if let accessible = child as? any NSAccessibilityProtocol {
                walk(accessible, depth: depth + 1)
            }
        }
    }

    walk(root, depth: 0)
    return snapshots
}

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

    func test_activeProfileCanUseCLIKeychainCredentialBeforeAccountUUIDBackfill() {
        let profileID = UUID()
        let credential = Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":9000000000000}}"#)!

        XCTAssertTrue(ProfileManager.canUseCLICredential(
            credential,
            for: profileID,
            expectedAccountUUID: "acct-1",
            activeProfileID: profileID
        ))
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

    func test_profileCardStaleMessageExplainsRateLimitInsteadOfClaudeCodeWait() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            ClaudeStalePresentation.waitingMessage(
                credentialSource: .cliSynced,
                isStale: true,
                lastSuccessAt: now.addingTimeInterval(-660),
                currentTime: now,
                errorMessage: "Rate limited — retrying soon"
            ),
            "Updated 11m ago — rate limited, retrying"
        )
    }

    @MainActor
    func test_profileCardStaleStatusIsOneLineWithoutRetryControl() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let card = ProfileCard(
            profile: Profile(name: "Claude", credentialSource: .cliSynced),
            usageData: UsageData(
                fiveHour: UsageWindow(utilization: 5, resetsAt: now.addingTimeInterval(-60)),
                sevenDay: UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(48 * 3_600))
            ),
            errorMessage: "Rate limited — retrying soon",
            lastSuccessAt: now.addingTimeInterval(-(4 * 3_600 + 6 * 60)),
            isStale: true,
            isCLIActive: false,
            showProfileName: false,
            currentTime: now
        )
        .padding(10)
        .frame(width: 260)

        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
        host.layoutSubtreeIfNeeded()

        let snapshots = accessibilitySnapshots(from: host)
        XCTAssertFalse(snapshots.contains {
            $0.role == .button && ($0.label == "Retry" || $0.value == "Retry")
        })
    }

    func test_fileLogUsesTemporaryDirectoryUnderXCTest() {
        let home = URL(fileURLWithPath: "/Users/test")
        let temp = URL(fileURLWithPath: "/tmp")

        XCTAssertEqual(
            FileLog.logsDirectory(
                homeDirectory: home,
                temporaryDirectory: temp,
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            ).path,
            "/tmp/ClimeterTests/Logs"
        )

        XCTAssertEqual(
            FileLog.logsDirectory(
                homeDirectory: home,
                temporaryDirectory: temp,
                environment: [:]
            ).path,
            "/Users/test/Library/Logs/Climeter"
        )
    }
}
