import XCTest
@testable import Climeter

final class ClaudeStatusLineUsageStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func test_refreshPublishesCompleteValidatedSnapshot() throws {
        let file = try temporaryUsageFile(#"""
        {
          "schema_version": 1,
          "updated_at": 1785290000,
          "rate_limits": {
            "five_hour": {"used_percentage": 23.5, "resets_at": 1785300000},
            "seven_day": {"used_percentage": 41.2, "resets_at": null}
          }
        }
        """#)
        let store = ClaudeStatusLineUsageStore(fileURL: file)

        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.usageData?.sevenDay.utilization, 41.2)
        XCTAssertEqual(store.lastSuccessAt, Date(timeIntervalSince1970: 1_785_290_000))
        XCTAssertNil(store.errorMessage)
    }

    func test_refreshRejectsFutureSchemaWithoutDiscardingLastGoodUsage() throws {
        let file = try temporaryUsageFile(validFixture)
        let store = ClaudeStatusLineUsageStore(fileURL: file)
        store.refresh()
        try Data(#"{"schema_version":2,"updated_at":1785290100,"rate_limits":{}}"#.utf8)
            .write(to: file, options: .atomic)

        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.errorMessage, "Climeter usage exporter needs an update.")
    }

    func test_refreshMergesPartialWindowsBeforePublishingUsage() throws {
        let file = try temporaryUsageFile(fiveHourOnlyFixture)
        let store = ClaudeStatusLineUsageStore(fileURL: file)
        store.refresh()
        XCTAssertNil(store.usageData)
        XCTAssertEqual(store.errorMessage, "Claude supplied partial usage; waiting for both windows.")

        try Data(sevenDayOnlyFixture.utf8).write(to: file, options: .atomic)
        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(store.usageData?.sevenDay.utilization, 41.2)
    }

    func test_refreshRejectsNonFiniteOrOutOfRangePercentages() throws {
        for value in ["-1", "101", "1e999"] {
            let file = try temporaryUsageFile(invalidFixture(percentage: value))
            let store = ClaudeStatusLineUsageStore(fileURL: file)
            store.refresh()
            XCTAssertNil(store.usageData)
            XCTAssertEqual(store.errorMessage, "Claude usage file is invalid.")
        }
    }

    func test_refreshDerivesStalenessFromExporterTimestamp() throws {
        let file = try temporaryUsageFile(validFixture)
        let store = ClaudeStatusLineUsageStore(fileURL: file)
        let exportedAt = Date(timeIntervalSince1970: 1_785_290_000)

        store.refresh(now: exportedAt.addingTimeInterval(ClaudeStatusLineUsageStore.staleThreshold + 1))

        XCTAssertEqual(store.lastSuccessAt, exportedAt)
        XCTAssertTrue(store.isStale)
    }

    func test_refreshReportsMissingUsageFile() {
        let file = temporaryDirectory.appendingPathComponent("missing-claude-usage.json")
        let store = ClaudeStatusLineUsageStore(fileURL: file)

        store.refresh()

        XCTAssertNil(store.usageData)
        XCTAssertEqual(store.errorMessage, "Open Claude Code and send one prompt to initialize usage.")
    }

    func test_refreshUsesInjectedReaderWithoutRequiringFileOnDisk() {
        let file = temporaryDirectory.appendingPathComponent("in-memory-claude-usage.json")
        let fixture = validFixture
        let store = ClaudeStatusLineUsageStore(fileURL: file) { _ in
            Data(fixture.utf8)
        }

        store.refresh()

        XCTAssertEqual(store.usageData?.fiveHour.utilization, 23.5)
        XCTAssertNil(store.errorMessage)
    }
}

private extension ClaudeStatusLineUsageStoreTests {
    var validFixture: String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785300000},"seven_day":{"used_percentage":41.2,"resets_at":null}}}"#
    }

    var fiveHourOnlyFixture: String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785300000}}}"#
    }

    var sevenDayOnlyFixture: String {
        #"{"schema_version":1,"updated_at":1785290010,"rate_limits":{"seven_day":{"used_percentage":41.2,"resets_at":1785800000}}}"#
    }

    func invalidFixture(percentage: String) -> String {
        #"{"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":\#(percentage),"resets_at":1785300000},"seven_day":{"used_percentage":41.2,"resets_at":1785800000}}}"#
    }

    func temporaryUsageFile(_ contents: String) throws -> URL {
        let file = temporaryDirectory.appendingPathComponent("claude-usage.json")
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }
}
