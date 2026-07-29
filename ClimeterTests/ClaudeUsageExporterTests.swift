import XCTest

final class ClaudeUsageExporterTests: XCTestCase {
    private var directory: URL!

    private var usageFile: URL {
        directory.appendingPathComponent("claude-usage.json")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_exporterWritesOnlyAllowlistedFieldsAndOwnerPermissions() throws {
        let input = #"""
        {
          "session_id":"session-secret",
          "prompt_id":"prompt-secret",
          "transcript_path":"/private/transcript",
          "oauth":{"accessToken":"do-not-copy"},
          "rate_limits":{
            "five_hour":{"used_percentage":20,"resets_at":1785300000},
            "seven_day":{"used_percentage":40,"resets_at":1785800000}
          }
        }
        """#

        try runExporter(input: input, directory: directory)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: usageFile)) as? [String: Any]
        )
        try assertExactCompleteSchema(object)
        let contents = try XCTUnwrap(
            String(data: Data(contentsOf: usageFile), encoding: .utf8)
        )
        XCTAssertFalse(contents.contains("do-not-copy"))
        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: usageFile), 0o600)
        XCTAssertEqual(
            try permissions(of: directory.appendingPathComponent("claude-usage.lock")),
            0o600
        )
    }

    func test_exporterSanitizesTaintedExistingAggregateAndInvalidTimestamp() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let taintedAggregate = #"""
        {
          "schema_version":1,
          "updated_at":"not-a-timestamp",
          "rate_limits":{
            "five_hour":{"used_percentage":20,"resets_at":1785300000},
            "seven_day":{
              "used_percentage":40,
              "resets_at":1785800000,
              "oauth_token":"old-secret"
            }
          },
          "session_id":"old-session-secret"
        }
        """#
        try Data(taintedAggregate.utf8).write(to: usageFile)

        try runExporter(input: fiveHourOnlyFixture, directory: directory)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: usageFile)) as? [String: Any]
        )
        try assertExactCompleteSchema(object)
        let contents = try XCTUnwrap(
            String(data: Data(contentsOf: usageFile), encoding: .utf8)
        )
        XCTAssertFalse(contents.contains("old-secret"))
        XCTAssertFalse(contents.contains("old-session-secret"))
    }

    func test_exporterSerializesConcurrentWritersAndRejectsOlderWindow() throws {
        try runExporter(input: newerFixture, directory: directory)
        try runConcurrently([olderFixture, newestFixture], directory: directory)

        let result = try decodedUsageFile()

        XCTAssertEqual(result.fiveHour.usedPercentage, 55)
        XCTAssertEqual(result.fiveHour.resetsAt, 1_785_400_000)
        XCTAssertTrue(try temporaryExporterFiles(in: directory).isEmpty)
    }

    func test_exporterSerializesBlockedConcurrentPartialWritersWithoutLostUpdate() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockHolder = try holdExporterLock()
        defer {
            if lockHolder.isRunning {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
        }
        let processes = [fiveHourOnlyFixture, sevenDayOnlyFixture]
            .map { makeExporter(input: $0, directory: directory).0 }
        try processes.forEach { try $0.run() }

        XCTAssertTrue(try waitForExporterCandidates(count: 2, timeout: 0.75))
        lockHolder.terminate()
        lockHolder.waitUntilExit()
        processes.forEach { $0.waitUntilExit() }

        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
        XCTAssertEqual(
            try decodedUsageFile().rateLimits.keys.sorted(),
            ["five_hour", "seven_day"]
        )
        XCTAssertTrue(try temporaryExporterFiles(in: directory).isEmpty)
    }

    func test_exporterPreservesUpdatedAtForUnchangedRateLimits() throws {
        try runExporter(input: completeFixture, directory: directory)
        let first = try decodedUsageFile()
        sleep(1)
        try runExporter(input: completeFixture, directory: directory)
        let second = try decodedUsageFile()

        XCTAssertEqual(second.updatedAt, first.updatedAt)
    }

    func test_exporterMergesIndependentlyPresentWindows() throws {
        try runExporter(input: fiveHourOnlyFixture, directory: directory)
        try runExporter(input: sevenDayOnlyFixture, directory: directory)

        XCTAssertEqual(try decodedUsageFile().rateLimits.count, 2)
    }

    func test_exporterGracefullyIgnoresInvalidInputWithoutChangingLastAggregate() throws {
        try runExporter(input: completeFixture, directory: directory)
        let original = try Data(contentsOf: usageFile)

        let invalidJSON = try executeExporter(input: #"{"rate_limits":"#, directory: directory)
        let noUsableWindow = try executeExporter(
            input: #"{"rate_limits":{"five_hour":{"used_percentage":101}}}"#,
            directory: directory
        )

        XCTAssertEqual(invalidJSON.terminationStatus, 0)
        XCTAssertEqual(noUsableWindow.terminationStatus, 0)
        XCTAssertTrue(invalidJSON.standardOutput.isEmpty)
        XCTAssertTrue(noUsableWindow.standardOutput.isEmpty)
        XCTAssertEqual(try Data(contentsOf: usageFile), original)
        XCTAssertTrue(try temporaryExporterFiles(in: directory).isEmpty)
    }

    func test_exporterRejectsIncomingInfiniteResetAndLaterFiniteWindowRecovers() throws {
        try runExporter(input: completeFixture, directory: directory)
        let original = try Data(contentsOf: usageFile)

        try runExporter(
            input: #"{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1e999}}}"#,
            directory: directory
        )

        XCTAssertEqual(try Data(contentsOf: usageFile), original)

        try runExporter(input: newerFixture, directory: directory)

        XCTAssertEqual(try decodedUsageFile().fiveHour.usedPercentage, 50)
        XCTAssertEqual(try decodedUsageFile().fiveHour.resetsAt, 1_785_400_000)
    }

    func test_exporterDiscardsPersistedInfiniteResetAndAcceptsLaterFiniteWindow() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let taintedAggregate = #"""
        {
          "schema_version":1,
          "updated_at":1785290000,
          "rate_limits":{
            "five_hour":{"used_percentage":99,"resets_at":1e999},
            "seven_day":{"used_percentage":40,"resets_at":1785800000}
          }
        }
        """#
        try Data(taintedAggregate.utf8).write(to: usageFile)

        try runExporter(input: newerFixture, directory: directory)

        XCTAssertEqual(try decodedUsageFile().fiveHour.usedPercentage, 50)
        XCTAssertEqual(try decodedUsageFile().fiveHour.resetsAt, 1_785_400_000)
        XCTAssertEqual(try decodedUsageFile().rateLimits.count, 2)
    }

    func test_exporterGracefullyTimesOutOnBusyLockWithoutChangingLastAggregate() throws {
        try runExporter(input: completeFixture, directory: directory)
        let original = try Data(contentsOf: usageFile)
        let lockHolder = try holdExporterLock()
        defer {
            lockHolder.terminate()
            lockHolder.waitUntilExit()
        }

        let result = try executeExporter(input: newerFixture, directory: directory)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertEqual(try Data(contentsOf: usageFile), original)
        XCTAssertTrue(try temporaryExporterFiles(in: directory).isEmpty)
    }

    private var completeFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785300000},"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var fiveHourOnlyFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1785300000}}}"#
    }

    private var sevenDayOnlyFixture: String {
        #"{"rate_limits":{"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var newerFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1785400000},"seven_day":{"used_percentage":40,"resets_at":1785800000}}}"#
    }

    private var olderFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1785300000}}}"#
    }

    private var newestFixture: String {
        #"{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":1785400000}}}"#
    }

    private var exporterURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/claude-usage-export.sh")
    }

    private func makeExporter(input: String, directory: URL) -> (Process, Pipe, Pipe) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [exporterURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CLIMETER_USAGE_DIR": directory.path],
            uniquingKeysWith: { _, override in override }
        )
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try! stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try! stdin.fileHandleForWriting.close()
        return (process, stdin, stdout)
    }

    private func executeExporter(input: String, directory: URL) throws -> ExporterResult {
        let (process, _, stdout) = makeExporter(input: input, directory: directory)
        try process.run()
        process.waitUntilExit()
        return ExporterResult(
            terminationStatus: process.terminationStatus,
            standardOutput: stdout.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func runExporter(input: String, directory: URL) throws {
        let result = try executeExporter(input: input, directory: directory)
        XCTAssertEqual(result.terminationStatus, 0)
    }

    private func runConcurrently(_ inputs: [String], directory: URL) throws {
        let processes = inputs.map { makeExporter(input: $0, directory: directory).0 }
        try processes.forEach { try $0.run() }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
    }

    private func holdExporterLock() throws -> Process {
        let readyFile = directory.appendingPathComponent("lock-holder-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-k",
            directory.appendingPathComponent("claude-usage.lock").path,
            "/bin/sh",
            "-c",
            "touch \"$1\"; exec /bin/sleep 10",
            "lock-holder",
            readyFile.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyFile.path), Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyFile.path))
        return process
    }

    private func permissions(of url: URL) throws -> Int {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        ) & 0o777
    }

    private func temporaryExporterFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(".tmp.") ||
                $0.lastPathComponent.contains(".candidate.") ||
                $0.lastPathComponent.contains(".old.")
        }
    }

    private func waitForExporterCandidates(
        count: Int,
        timeout: TimeInterval
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            ).filter {
                $0.lastPathComponent.contains(".candidate.")
            }
            if candidates.count == count,
               try candidates.allSatisfy({
                   try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0
               }) {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func assertExactCompleteSchema(_ object: [String: Any]) throws {
        XCTAssertEqual(Set(object.keys), ["schema_version", "updated_at", "rate_limits"])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertNotNil(object["updated_at"] as? NSNumber)

        let rateLimits = try XCTUnwrap(object["rate_limits"] as? [String: Any])
        XCTAssertEqual(Set(rateLimits.keys), ["five_hour", "seven_day"])
        for key in ["five_hour", "seven_day"] {
            let window = try XCTUnwrap(rateLimits[key] as? [String: Any])
            XCTAssertEqual(Set(window.keys), ["used_percentage", "resets_at"])
        }
    }

    private func decodedUsageFile() throws -> ExportedUsageFile {
        try JSONDecoder().decode(ExportedUsageFile.self, from: Data(contentsOf: usageFile))
    }
}

private struct ExporterResult {
    let terminationStatus: Int32
    let standardOutput: Data
}

private struct ExportedUsageFile: Decodable {
    let updatedAt: Int
    let rateLimits: [String: ExportedWindow]

    var fiveHour: ExportedWindow { rateLimits["five_hour"]! }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case rateLimits = "rate_limits"
    }
}

private struct ExportedWindow: Decodable {
    let usedPercentage: Double
    let resetsAt: Int?

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}
