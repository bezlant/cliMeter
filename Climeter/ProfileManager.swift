import Foundation
import SwiftUI
import Combine

class ProfileManager: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var allUsageData: [UUID: UsageData] = [:]
    @Published var allErrors: [UUID: String] = [:]
    @Published var allLastSuccess: [UUID: Date] = [:]
    @Published var allStale: [UUID: Bool] = [:]
    @Published var cliActiveProfileID: UUID?
    @Published private(set) var authenticatedProfileIDs: Set<UUID> = []
    @Published var codexUsageData: UsageData?
    @Published var codexErrorMessage: String?
    @Published var codexLastSuccessAt: Date?
    private static let readOnlyCredentialFileBackupDoneKey = "readOnlyMigrationDone"
    private static let readOnlyProfileMigrationDoneKey = "readOnlyProfileMigrationDone"
    @Published var claudeEnabled: Bool = true {
        didSet {
            ProfileStore.saveClaudeEnabled(claudeEnabled)
            if claudeEnabled {
                refreshAuthenticatedIDs()
                setupAllCoordinators()
                backfillAccountUUIDs()
                startCLIMonitoring()
            } else {
                stopCLIMonitoring()
                cliIdentificationTask?.cancel()
                cliIdentificationTask = nil
                autoStartTask?.cancel()
                autoStartTask = nil
                backfillTasks.forEach { $0.cancel() }
                backfillTasks.removeAll()
                for profileID in Array(coordinators.keys) {
                    teardownCoordinator(for: profileID)
                }
            }
        }
    }
    @Published var codexEnabled: Bool = true {
        didSet {
            ProfileStore.saveCodexEnabled(codexEnabled)
            if codexEnabled {
                codexCoordinator.startPolling()
            } else {
                codexCoordinator.stopPolling()
                codexUsageData = nil
                codexErrorMessage = nil
                codexLastSuccessAt = nil
            }
        }
    }
    @Published var peakHoursEnabled: Bool = true {
        didSet { ProfileStore.savePeakHoursEnabled(peakHoursEnabled) }
    }
    @Published var autoSwitchEnabled: Bool = false {
        didSet { ProfileStore.saveAutoSwitchEnabled(autoSwitchEnabled) }
    }
    @Published var autoSwitchThreshold: Double = 95.0 {
        didSet { ProfileStore.saveAutoSwitchThreshold(autoSwitchThreshold) }
    }

    private var coordinators: [UUID: UsageRefreshCoordinator] = [:]
    private var cancellables: [UUID: [AnyCancellable]] = [:]
    private let codexCoordinator = CodexUsageRefreshCoordinator()
    private var codexCancellables: [AnyCancellable] = []
    private var cachedCredentials: [UUID: Credential] = [:]
    private var lastAutoSwitchDate: Date?
    private let powerMonitor = PowerStateMonitor()
    private var hasResumedSinceLastSleep = false
    private var cliIdentificationTask: Task<Void, Never>?
    private var autoStartTask: Task<Void, Never>?
    private var backfillTasks: [Task<Void, Never>] = []

    // Convenience for menu bar: usage data for CLI-active profile
    var cliActiveUsageData: UsageData? {
        guard let id = cliActiveProfileID else { return nil }
        return allUsageData[id]
    }

    var cliActiveProfile: Profile? {
        guard let id = cliActiveProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    var hasAnyAuthenticated: Bool {
        !authenticatedProfileIDs.isEmpty
    }

    var authenticatedProfiles: [Profile] {
        profiles.filter { authenticatedProfileIDs.contains($0.id) }
    }

    init() {
        loadProfiles()
        performReadOnlyMigrationIfNeeded()
        refreshAuthenticatedIDs()
        loadCLIActiveProfileID()
        peakHoursEnabled = ProfileStore.loadPeakHoursEnabled()
        autoSwitchEnabled = ProfileStore.loadAutoSwitchEnabled()
        autoSwitchThreshold = ProfileStore.loadAutoSwitchThreshold()
        codexEnabled = ProfileStore.loadCodexEnabled()
        claudeEnabled = ProfileStore.loadClaudeEnabled()
        Log.profiles.info("init: \(self.profiles.count) profiles, \(self.authenticatedProfileIDs.count) authenticated, cliActive=\(self.cliActiveProfileID?.uuidString ?? "none")")
        if claudeEnabled {
            setupAllCoordinators()
            backfillAccountUUIDs()
            startCLIMonitoring()
        }
        setupCodexCoordinator()
        if codexEnabled {
            codexCoordinator.startPolling()
        }
        setupPowerMonitor()
    }

    private func refreshAuthenticatedIDs() {
        let state = Self.computeAuthenticationState(
            profiles: profiles,
            existingCredentials: cachedCredentials,
            storedCredential: { ProfileStore.loadCredentialModel(for: $0) },
            authenticatedMarkers: ProfileStore.authenticatedMarkers()
        )
        cachedCredentials = state.credentials
        authenticatedProfileIDs = state.authenticatedProfileIDs
    }

    func cachedCredential(for profileID: UUID) -> Credential? {
        cachedCredentials[profileID]
    }

    func updateCachedCredential(_ credential: Credential, for profileID: UUID) {
        cachedCredentials[profileID] = credential
    }

    /// cliSynced: keep token in memory only; persist metadata + authenticated marker.
    /// selfOwned: persist the secret as before.
    private func persistCredential(_ cred: Credential, for id: UUID) {
        let source = profiles.first { $0.id == id }?.credentialSource ?? .cliSynced
        cachedCredentials[id] = cred
        if Self.shouldPersistSecret(for: source) {
            try? ProfileStore.saveCredentialModel(cred, for: id)
        } else {
            ProfileStore.saveAccountMetadata(cred, for: id)
        }
    }

    static func shouldPersistSecret(for source: CredentialSource) -> Bool {
        source == .selfOwned
    }

    struct AuthenticationState {
        let credentials: [UUID: Credential]
        let authenticatedProfileIDs: Set<UUID>
    }

    static func computeAuthenticationState(
        profiles: [Profile],
        existingCredentials: [UUID: Credential],
        storedCredential: (UUID) -> Credential?,
        authenticatedMarkers: Set<UUID>
    ) -> AuthenticationState {
        var credentials: [UUID: Credential] = [:]
        for profile in profiles {
            if let existing = existingCredentials[profile.id] {
                credentials[profile.id] = existing
            } else if shouldPersistSecret(for: profile.credentialSource),
                      let stored = storedCredential(profile.id) {
                credentials[profile.id] = stored
            }
        }
        return AuthenticationState(
            credentials: credentials,
            authenticatedProfileIDs: Set(credentials.keys).union(authenticatedMarkers)
        )
    }

    private func readCLICredential(for profileID: UUID) -> Credential? {
        guard let credential = ClaudeCodeSyncService.readCLICredential(interactive: false) else {
            return nil
        }

        let expectedUUID = ProfileStore.accountUUID(for: profileID)
        if !Self.canUseCLICredential(
            credential,
            for: profileID,
            expectedAccountUUID: expectedUUID,
            activeProfileID: cliActiveProfileID
        ) {
            if cliActiveProfileID == profileID { processCLICredential(credential) }
            return nil
        }

        return credential
    }

    static func canUseCLICredential(
        _ credential: Credential,
        for profileID: UUID,
        expectedAccountUUID: String?,
        activeProfileID: UUID?
    ) -> Bool {
        if let expectedAccountUUID, let credentialUUID = credential.accountUUID {
            return credentialUUID == expectedAccountUUID
        }
        return activeProfileID == profileID
    }

    // MARK: - Initialization

    private func loadProfiles() {
        profiles = ProfileStore.loadProfiles()
        if profiles.isEmpty {
            let defaultProfile = Profile(name: "Default")
            profiles = [defaultProfile]
            ProfileStore.saveProfiles(profiles)
        }
    }

    private func performReadOnlyMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyMigrationDone = defaults.bool(forKey: Self.readOnlyCredentialFileBackupDoneKey)
        let profileMigrationDone = defaults.bool(forKey: Self.readOnlyProfileMigrationDoneKey)
        let migrationPlan = Self.readOnlyMigrationPlan(
            legacyCredentialFileBackupDone: legacyMigrationDone,
            profileMigrationDone: profileMigrationDone
        )

        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        let credentialFileName = ".credentials" + ".json"
        let fileURL = claudeDir.appendingPathComponent(credentialFileName)
        let backupURL = claudeDir.appendingPathComponent("\(credentialFileName).climeter-bak")
        let keychainExists = ClaudeCodeSyncService.keychainItemExists()

        if migrationPlan.runProfileMigration {
            profiles = Self.migrateProfilesToReadOnly(
                profiles: profiles,
                storedCredential: { Self.readOnlyMigrationCredential(for: $0) },
                saveMetadata: { credential, profileID in ProfileStore.saveAccountMetadata(credential, for: profileID) },
                purgeSecret: { ProfileStore.deleteCredentialFromAllStores(for: $0) },
                markAuthenticated: { ProfileStore.markAuthenticated($0) }
            )
            ProfileStore.saveProfiles(profiles)
            defaults.set(true, forKey: Self.readOnlyProfileMigrationDoneKey)
        }

        guard migrationPlan.runCredentialFileBackup else { return }

        Self.backupStaleCredentialFile(
            keychainExists: keychainExists,
            fileURL: fileURL,
            backupURL: backupURL,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            moveFile: { source, destination in
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            defaults.set(true, forKey: Self.readOnlyCredentialFileBackupDoneKey)
        } else if !keychainExists {
            Log.profiles.warning("readOnlyMigration: keychain unavailable; will retry stale file backup next launch")
        } else {
            Log.profiles.warning("readOnlyMigration: credential file backup failed; will retry next launch")
        }
    }

    private func loadCLIActiveProfileID() {
        if let savedID = ProfileStore.loadCLIActiveProfileID(),
           profiles.contains(where: { $0.id == savedID }) {
            cliActiveProfileID = savedID
        }
    }

    // MARK: - CLI Account Detection

    private func startCLIMonitoring() {
        // Initial check after short delay (gives backfill time)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.detectCLIAccountChange()
        }
    }

    private func stopCLIMonitoring() {
    }

    private func detectCLIAccountChange() {
        guard claudeEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cliCredential = ClaudeCodeSyncService.readCLICredential(interactive: false)
            DispatchQueue.main.async {
                self?.processCLICredential(cliCredential)
            }
        }
    }

    private func processCLICredential(_ cliCredential: Credential?) {
        guard claudeEnabled, let cliCredential else { return }

        cliIdentificationTask?.cancel()

        // Quick check: if tokens match CLI-active profile, nothing changed
        if let activeID = cliActiveProfileID,
           let cached = cachedCredentials[activeID] {
            if cached.refreshToken == cliCredential.refreshToken
                || cached.accessToken == cliCredential.accessToken {
                return
            }
        }

        Log.profiles.info("detectCLI: credential changed, identifying account...")

        cliIdentificationTask = Task {
            await self.identifyAndSyncAccount(cliCredential)
        }
    }

    @MainActor
    private func identifyAndSyncAccount(_ cliCredential: Credential) async {
        guard claudeEnabled, !Task.isCancelled else { return }
        var credential = cliCredential

        guard claudeEnabled, !Task.isCancelled else { return }

        guard let apiProfile = try? await ClaudeAPIService.fetchProfile(credential: credential) else {
            Log.profiles.warning("detectCLI: fetchProfile failed")
            return
        }

        guard claudeEnabled, !Task.isCancelled else { return }

        credential.accountUUID = apiProfile.uuid
        Log.profiles.info("detectCLI: account=\(apiProfile.uuid) name=\(apiProfile.displayName)")

        // Match by accountUUID
        for profile in profiles {
            let accountUUID = cachedCredentials[profile.id]?.accountUUID ?? ProfileStore.accountUUID(for: profile.id)
            if accountUUID == apiProfile.uuid {
                Log.profiles.info("detectCLI: matched existing profile '\(profile.name)'")
                saveAndActivate(credential: credential, profileID: profile.id)
                return
            }
        }

        // Eagerly resolve profiles with nil accountUUID (migration/backfill race)
        for profile in profiles {
            guard let stored = cachedCredentials[profile.id],
                  stored.accountUUID == nil else { continue }
            Log.profiles.info("detectCLI: resolving accountUUID for '\(profile.name)'...")
            let storedProfile = try? await ClaudeAPIService.fetchProfile(credential: stored)
            guard claudeEnabled, !Task.isCancelled else { return }
            if let storedProfile {
                var updated = stored
                updated.accountUUID = storedProfile.uuid
                persistCredential(updated, for: profile.id)
                if storedProfile.uuid == apiProfile.uuid {
                    Log.profiles.info("detectCLI: resolved match → '\(profile.name)'")
                    saveAndActivate(credential: credential, profileID: profile.id)
                    return
                }
            }
        }

        guard claudeEnabled, !Task.isCancelled else { return }

        // New account — assign to first unauthenticated profile or create one
        if let target = profiles.first(where: { !authenticatedProfileIDs.contains($0.id) }) {
            Log.profiles.info("detectCLI: new account → unauthenticated profile '\(target.name)'")
            saveAndActivate(credential: credential, profileID: target.id)
        } else {
            let newProfile = Profile(name: apiProfile.displayName)
            profiles.append(newProfile)
            ProfileStore.saveProfiles(profiles)
            Log.profiles.info("detectCLI: new account → created profile '\(apiProfile.displayName)'")
            saveAndActivate(credential: credential, profileID: newProfile.id)
        }
    }

    private func saveAndActivate(credential: Credential, profileID: UUID) {
        guard claudeEnabled else { return }
        persistCredential(credential, for: profileID)
        refreshAuthenticatedIDs()
        if cliActiveProfileID != profileID {
            cliActiveProfileID = profileID
            ProfileStore.saveCLIActiveProfileID(profileID)
        }
        if coordinators[profileID] == nil {
            setupCoordinator(for: profileID)
        }
    }

    /// Backfill accountUUID for profiles that were created before account detection
    private func backfillAccountUUIDs() {
        let needsBackfill = profiles.filter { p in
            guard let cred = cachedCredentials[p.id] else { return false }
            return cred.accountUUID == nil
        }
        guard !needsBackfill.isEmpty else { return }
        Log.profiles.info("backfill: \(needsBackfill.count) profiles need accountUUID")

        backfillTasks.forEach { $0.cancel() }
        backfillTasks.removeAll()
        for profile in needsBackfill {
            guard let credential = cachedCredentials[profile.id] else { continue }
            let task = Task {
                guard let apiProfile = try? await ClaudeAPIService.fetchProfile(credential: credential) else {
                    Log.profiles.error("backfill: failed for '\(profile.name)'")
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.claudeEnabled, !Task.isCancelled else { return }
                    var updated = self.cachedCredentials[profile.id] ?? credential
                    updated.accountUUID = apiProfile.uuid
                    self.persistCredential(updated, for: profile.id)
                    Log.profiles.info("backfill: set accountUUID for '\(profile.name)' → \(apiProfile.uuid)")
                }
            }
            backfillTasks.append(task)
        }
    }

    static func migrateProfilesToReadOnly(
        profiles: [Profile],
        storedCredential: (UUID) -> Credential?,
        saveMetadata: (Credential, UUID) -> Void,
        purgeSecret: (UUID) -> Void,
        markAuthenticated: (UUID) -> Void
    ) -> [Profile] {
        var updated = profiles
        for i in updated.indices {
            updated[i].credentialSource = .cliSynced
            if let credential = storedCredential(updated[i].id) {
                saveMetadata(credential, updated[i].id)
                markAuthenticated(updated[i].id)
            }
            purgeSecret(updated[i].id)
        }
        return updated
    }

    static func readOnlyMigrationCredential(
        for profileID: UUID,
        keychainCredential: (UUID) -> Credential? = { ProfileStore.loadCredentialModel(for: $0) },
        fileCredentialRaw: (UUID) -> String? = { FileCredentialStore.read(for: $0) }
    ) -> Credential? {
        if let credential = keychainCredential(profileID) { return credential }
        guard let raw = fileCredentialRaw(profileID) else { return nil }
        return Credential(jsonString: raw)
    }

    static func backupStaleCredentialFile(
        keychainExists: Bool,
        fileURL: URL,
        backupURL: URL,
        fileExists: (URL) -> Bool,
        moveFile: (URL, URL) -> Void
    ) {
        if keychainExists, fileExists(fileURL) { moveFile(fileURL, backupURL) }
    }

    struct ReadOnlyMigrationPlan {
        let runProfileMigration: Bool
        let runCredentialFileBackup: Bool
    }

    static func readOnlyMigrationPlan(
        legacyCredentialFileBackupDone: Bool,
        profileMigrationDone: Bool
    ) -> ReadOnlyMigrationPlan {
        ReadOnlyMigrationPlan(
            runProfileMigration: !profileMigrationDone,
            runCredentialFileBackup: !legacyCredentialFileBackupDone
        )
    }

    private func setupPowerMonitor() {
        powerMonitor.onSleep = { [weak self] in
            guard let self else { return }
            self.hasResumedSinceLastSleep = false
            for coordinator in self.coordinators.values {
                coordinator.stopPolling()
            }
            self.codexCoordinator.stopPolling()
        }

        powerMonitor.onWake = { [weak self] in
            // Don't resume yet — keychain may still be locked.
            // Wait for onScreenUnlocked. But if screen lock is
            // not required (e.g. no password after sleep), wake
            // alone is enough — schedule a delayed retry.
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.powerMonitor.isScreenLocked else { return }
                self.resumeAfterWake()
            }
        }

        powerMonitor.onScreenUnlocked = { [weak self] in
            self?.resumeAfterWake()
        }

        powerMonitor.startMonitoring()
    }

    private func resumeAfterWake() {
        guard !hasResumedSinceLastSleep else { return }
        hasResumedSinceLastSleep = true
        Log.profiles.info("resumeAfterWake: re-reading keychain and restarting coordinators")

        if claudeEnabled {
            refreshAuthenticatedIDs()
            Log.profiles.info("resumeAfterWake: \(self.authenticatedProfileIDs.count) authenticated")

            for profile in profiles where authenticatedProfileIDs.contains(profile.id) {
                if coordinators[profile.id] == nil {
                    setupCoordinator(for: profile.id)
                } else {
                    coordinators[profile.id]?.startPolling()
                }
            }

            detectCLIAccountChange()
        }

        if codexEnabled {
            codexCoordinator.startPolling()
        }
    }

    // MARK: - Usage Coordinators

    private func setupAllCoordinators() {
        for profile in profiles where authenticatedProfileIDs.contains(profile.id) {
            setupCoordinator(for: profile.id)
        }
    }

    private func setupCodexCoordinator() {
        codexCancellables = [
            codexCoordinator.$usageData
                .receive(on: DispatchQueue.main)
                .sink { [weak self] data in self?.codexUsageData = data },
            codexCoordinator.$errorMessage
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in self?.codexErrorMessage = message },
            codexCoordinator.$lastSuccessAt
                .receive(on: DispatchQueue.main)
                .sink { [weak self] date in self?.codexLastSuccessAt = date }
        ]
    }

    private func setupCoordinator(for profileID: UUID) {
        // Don't create duplicates
        guard coordinators[profileID] == nil else { return }
        Log.profiles.info("setupCoordinator for \(profileID)")

        let source = profiles.first { $0.id == profileID }?.credentialSource ?? .cliSynced
        let coordinator: UsageRefreshCoordinator
        if Self.usesReadOnlyCoordinator(for: source) {
            // The reader may detect a Claude Code account switch while reading.
            // It must remain read-only toward Claude Code, but can update Climeter profile metadata.
            coordinator = UsageRefreshCoordinator(
                profileID: profileID,
                readOnly: true,
                credentialProvider: { [weak self] in self?.cachedCredentials[profileID] },
                keychainReader: { [weak self] in self?.readCLICredential(for: profileID) },
                onCredentialCached: { [weak self] credential in
                    self?.cachedCredentials[profileID] = credential
                },
                onAutoStart: { [weak self] credential in
                    guard let self, self.claudeEnabled,
                          self.cliActiveProfileID == profileID else { return }
                    self.autoStartTask?.cancel()
                    self.autoStartTask = Task {
                        await ClaudeAPIService.startSession(credential: credential)
                    }
                }
            )
        } else {
            coordinator = UsageRefreshCoordinator(
                profileID: profileID,
                readOnly: false,
                credentialProvider: { [weak self] in self?.cachedCredentials[profileID] },
                onCredentialRefreshed: { [weak self] refreshed in
                    guard self?.claudeEnabled == true else { return }
                    self?.cachedCredentials[profileID] = refreshed
                    try? ProfileStore.saveCredentialModel(refreshed, for: profileID)
                },
                onAutoStart: { [weak self] credential in
                    guard let self, self.claudeEnabled,
                          self.cliActiveProfileID == profileID else { return }
                    self.autoStartTask?.cancel()
                    self.autoStartTask = Task {
                        await ClaudeAPIService.startSession(credential: credential)
                    }
                }
            )
        }

        let usageSink = coordinator.$usageData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.allUsageData[profileID] = data
                self?.checkAutoSwitch()
            }
        let errorSink = coordinator.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                self?.allErrors[profileID] = msg
            }
        let lastSuccessSink = coordinator.$lastSuccessAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] date in
                self?.allLastSuccess[profileID] = date
            }
        let staleSink = coordinator.$isStale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isStale in
                self?.allStale[profileID] = isStale
            }
        cancellables[profileID] = [usageSink, errorSink, lastSuccessSink, staleSink]
        coordinators[profileID] = coordinator
        coordinator.startPolling()
    }

    static func usesReadOnlyCoordinator(for source: CredentialSource) -> Bool {
        source == .cliSynced
    }

    private func teardownCoordinator(for profileID: UUID) {
        coordinators[profileID]?.stopPolling()
        coordinators.removeValue(forKey: profileID)
        cancellables.removeValue(forKey: profileID)
        allUsageData.removeValue(forKey: profileID)
        allErrors.removeValue(forKey: profileID)
        allLastSuccess.removeValue(forKey: profileID)
        allStale.removeValue(forKey: profileID)
    }

    // MARK: - Auto-Switch

    private func checkAutoSwitch() {
        guard claudeEnabled,
              autoSwitchEnabled,
              let activeID = cliActiveProfileID,
              let activeData = allUsageData[activeID],
              activeData.fiveHour.utilization >= autoSwitchThreshold else { return }

        // Cooldown: don't flip-flop more than once per 60s
        if let last = lastAutoSwitchDate, Date().timeIntervalSince(last) < 60 { return }

        // Find first authenticated profile under threshold
        let candidate = profiles.first { profile in
            profile.id != activeID
                && profile.credentialSource == .selfOwned
                && authenticatedProfileIDs.contains(profile.id)
                && (allUsageData[profile.id]?.fiveHour.utilization ?? 100) < autoSwitchThreshold
        }

        guard let target = candidate else { return }
        Log.profiles.info("autoSwitch: \(activeID) at \(activeData.fiveHour.utilization)% -> switching to \(target.id)")
        lastAutoSwitchDate = Date()
        activateForCLI(profileID: target.id)
    }

    // MARK: - Public API

    func refresh() {
        if claudeEnabled {
            for coordinator in coordinators.values {
                coordinator.refresh(forceKeychainReread: true)
            }
        }
        if codexEnabled {
            codexCoordinator.refresh()
        }
    }

    func activateForCLI(profileID: UUID) {
        // Climeter no longer switches Claude Code's active account. Switch
        // accounts inside Claude Code; Climeter follows via CLI monitoring.
        cliActiveProfileID = profileID
        ProfileStore.saveCLIActiveProfileID(profileID)
    }

    func createProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newProfile = Profile(name: trimmed)
        profiles.append(newProfile)
        ProfileStore.saveProfiles(profiles)
    }

    func renameProfile(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }

        profiles[index].name = trimmed
        ProfileStore.saveProfiles(profiles)
    }

    func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }

        teardownCoordinator(for: id)

        if cliActiveProfileID == id {
            cliActiveProfileID = profiles.first(where: { $0.id != id })?.id
            ProfileStore.saveCLIActiveProfileID(cliActiveProfileID)
        }

        profiles.remove(at: index)
        ProfileStore.saveProfiles(profiles)
        ProfileStore.deleteCredentialFromAllStores(for: id)
        ProfileStore.clearAccountMetadata(id)
        ProfileStore.clearAuthenticated(id)
        refreshAuthenticatedIDs()
    }

    func removeCredential(for profileID: UUID) {
        teardownCoordinator(for: profileID)
        ProfileStore.deleteCredentialFromAllStores(for: profileID)
        ProfileStore.clearAccountMetadata(profileID)
        ProfileStore.clearAuthenticated(profileID)
        refreshAuthenticatedIDs()
    }

    deinit {
        stopCLIMonitoring()
        for coordinator in coordinators.values {
            coordinator.stopPolling()
        }
        codexCoordinator.stopPolling()
    }
}
