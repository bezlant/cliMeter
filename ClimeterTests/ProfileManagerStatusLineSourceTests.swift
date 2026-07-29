import XCTest
@testable import Climeter

final class ProfileManagerStatusLineSourceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var usageFile: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        ProfileStore.saveCodexEnabled(false)
        ProfileStore.saveClaudeEnabled(true)

        defaultsSuiteName = "ProfileManagerStatusLineSourceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        usageFile = temporaryDirectory.appendingPathComponent("claude-usage.json")
        try writeUsage(fiveHour: 23.5, sevenDay: 41.2)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }

    func test_statusLineFileIsDefaultAndPersistedSource() {
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .statusLineFile)

        ProfileStore.saveClaudeUsageSource(.keychainManual, defaults: defaults)

        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .keychainManual)
    }

    func test_statusLineLifecycleNeverCallsCredentialDependencies() {
        let calls = CredentialCallRecorder()
        let power = TestPowerStateMonitor()
        let manager = ProfileManager(
            dependencies: dependencies(power: power, calls: calls),
            defaults: defaults
        )

        manager.refresh()
        power.onSleep?()
        power.onWake?()
        power.onScreenUnlocked?()
        manager.claudeEnabled = false
        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))

        XCTAssertEqual(calls.total, 0)
    }

    func test_freshStatusLineProfileOpensAllDisplayGates() throws {
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let profileID = try XCTUnwrap(manager.cliActiveProfileID)
        XCTAssertEqual(ProfileStore.loadCLIActiveProfileID(), profileID)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(profileID))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)
        XCTAssertEqual(manager.cliActiveUsageData?.sevenDay.utilization, 41.2)
        XCTAssertNil(manager.allErrors[profileID] ?? nil)
        XCTAssertEqual(
            manager.allLastSuccess[profileID],
            Date(timeIntervalSince1970: 1_785_290_000)
        )
        XCTAssertEqual(manager.allStale[profileID], true)
        XCTAssertTrue(manager.hasAnyAuthenticated)
    }

    func test_statusLineUsesValidPersistedProfileAndSurvivesAuthenticationRecomputation() throws {
        let first = Profile(name: "First")
        let selected = Profile(name: "Selected")
        ProfileStore.saveProfiles([first, selected])
        ProfileStore.saveCLIActiveProfileID(selected.id)
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)

        manager.claudeEnabled = false
        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(manager.cliActiveProfileID, selected.id)
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)
        XCTAssertTrue(manager.authenticatedProfileIDs.contains(selected.id))
    }

    func test_disablingClaudeStopsFileRefreshUntilReenabled() throws {
        let manager = ProfileManager(dependencies: dependencies(), defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 23.5)

        manager.claudeEnabled = false
        try writeUsage(fiveHour: 77, sevenDay: 88)
        manager.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertNil(manager.cliActiveUsageData)

        manager.claudeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(manager.cliActiveUsageData?.fiveHour.utilization, 77)
        XCTAssertEqual(manager.cliActiveUsageData?.sevenDay.utilization, 88)
    }

    func test_keychainCompatibilityReadsOnlyAfterExplicitSelectionAndTearsDownFileSource() {
        let calls = CredentialCallRecorder()
        let manager = ProfileManager(
            dependencies: dependencies(calls: calls),
            defaults: defaults
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls.total, 0)
        XCTAssertNotNil(manager.cliActiveUsageData)

        manager.claudeUsageSource = .keychainManual
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))

        XCTAssertGreaterThan(calls.total, 0)
        XCTAssertGreaterThan(calls.cliReads, 0)
        XCTAssertNil(manager.cliActiveUsageData)
        XCTAssertEqual(ProfileStore.loadClaudeUsageSource(defaults: defaults), .keychainManual)
    }

    private func writeUsage(fiveHour: Double, sevenDay: Double) throws {
        let json = """
        {"schema_version":1,"updated_at":1785290000,"rate_limits":{"five_hour":{"used_percentage":\(fiveHour),"resets_at":1785300000},"seven_day":{"used_percentage":\(sevenDay),"resets_at":1785800000}}}
        """
        try Data(json.utf8).write(to: usageFile, options: .atomic)
    }

    private func dependencies(
        power: TestPowerStateMonitor = TestPowerStateMonitor(),
        calls: CredentialCallRecorder = CredentialCallRecorder()
    ) -> ProfileManagerDependencies {
        ProfileManagerDependencies(
            readCLICredential: { _ in
                calls.cliReads += 1
                return nil
            },
            keychainItemExists: {
                calls.keychainExistenceChecks += 1
                return false
            },
            readMigrationCredential: { _ in
                calls.migrationReads += 1
                return nil
            },
            moveLegacyCredentialFile: { _, _ in
                calls.fileMoves += 1
            },
            makeStatusLineStore: {
                ClaudeStatusLineUsageStore(fileURL: self.usageFile)
            },
            powerMonitor: power
        )
    }
}

private final class CredentialCallRecorder {
    var cliReads = 0
    var keychainExistenceChecks = 0
    var migrationReads = 0
    var fileMoves = 0

    var total: Int {
        cliReads + keychainExistenceChecks + migrationReads + fileMoves
    }
}

private final class TestPowerStateMonitor: PowerStateMonitoring {
    var isScreenLocked = false
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onScreenUnlocked: (() -> Void)?

    func startMonitoring() {}
    func stopMonitoring() {}
}
