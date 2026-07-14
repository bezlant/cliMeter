import SwiftUI
import Vision
import XCTest
@testable import Climeter

private enum RenderedTextError: Error {
    case renderingFailed
}

@MainActor
private func renderedImage<V: View>(from view: V) throws -> CGImage {
    let renderer = ImageRenderer(content: view
        .background(Color.white)
        .environment(\.colorScheme, .light))
    renderer.scale = 8
    guard let image = renderer.cgImage else {
        throw RenderedTextError.renderingFailed
    }
    return image
}

private func recognizedText(in image: CGImage) throws -> [VNRecognizedText] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    return (request.results ?? []).compactMap { observation in
        observation.topCandidates(1).first
    }
}

private func recognizedTokens(in text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
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
    func test_profileCardRendersStaleStatusOnOneLineAtProductionWidth() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let expectedStatus = "Updated 4h 6m ago — rate limited, retrying"
        XCTAssertEqual(
            ClaudeStalePresentation.waitingMessage(
                credentialSource: .cliSynced,
                isStale: true,
                lastSuccessAt: now.addingTimeInterval(-(4 * 3_600 + 6 * 60)),
                currentTime: now,
                errorMessage: "Rate limited — retrying soon"
            ),
            expectedStatus
        )

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

        let image = try renderedImage(from: card)
        let observations = try recognizedText(in: image)
        let recognizedStrings = observations.map(\.string)
        let tokens = recognizedStrings.flatMap(recognizedTokens)

        XCTAssertTrue(tokens.contains("Claude"), "Rendered card text: \(recognizedStrings)")

        let expectedTokens = recognizedTokens(in: expectedStatus)
        let status = try XCTUnwrap(observations.first {
            recognizedTokens(in: $0.string) == expectedTokens
        }, "Rendered card text: \(recognizedStrings)")

        var tokenMidpoints: [CGFloat] = []
        var searchStart = status.string.startIndex
        for token in expectedTokens {
            let searchRange = searchStart..<status.string.endIndex
            let range = try XCTUnwrap(status.string.range(of: token, range: searchRange))
            let box = try XCTUnwrap(try status.boundingBox(for: range))
            tokenMidpoints.append(box.boundingBox.midY)
            searchStart = range.upperBound
        }

        let baselineSpread = try XCTUnwrap(tokenMidpoints.max()) - XCTUnwrap(tokenMidpoints.min())
        XCTAssertLessThanOrEqual(baselineSpread, 0.01)
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
