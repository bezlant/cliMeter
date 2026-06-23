import Foundation
import SwiftUI
import Combine

class ProfileManager: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var allUsageData: [UUID: UsageData] = [:]
    @Published var allErrors: [UUID: String] = [:]
    @Published var allLastSuccess: [UUID: Date] = [:]
    @Published var cliActiveProfileID: UUID?
    @Published private(set) var authenticatedProfileIDs: Set<UUID> = []
    @Published var codexUsageData: UsageData?
    @Published var codexErrorMessage: String?
    @Published var codexLastSuccessAt: Date?
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
    @Published var fileBasedStorage: Bool = ProfileStore.loadFileBasedStorage() {
        didSet {
            guard oldValue != fileBasedStorage else { return }
            migrateCredentialStorage(toFileBased: fileBasedStorage)
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
    private var cliMonitorTimer: Timer?
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
        var newCache: [UUID: Credential] = [:]
        for profile in profiles {
            if let credential = ProfileStore.loadCredentialModel(for: profile.id) {
                newCache[profile.id] = credential
            } else if let existing = cachedCredentials[profile.id] {
                // Keychain may be locked (sleep/dark wake) — keep cached credential
                Log.profiles.info("[\(profile.id)] keychain read failed, keeping cached credential")
                newCache[profile.id] = existing
            }
        }
        cachedCredentials = newCache
        authenticatedProfileIDs = Set(newCache.keys)
    }

    func cachedCredential(for profileID: UUID) -> Credential? {
        cachedCredentials[profileID]
    }

    func updateCachedCredential(_ credential: Credential, for profileID: UUID) {
        cachedCredentials[profileID] = credential
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
        cliMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.detectCLIAccountChange()
        }
    }

    private func stopCLIMonitoring() {
        cliMonitorTimer?.invalidate()
        cliMonitorTimer = nil
    }

    private func detectCLIAccountChange() {
        guard claudeEnabled else { return }
        let preferFile = fileBasedStorage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cliCredential = ClaudeCodeSyncService.readCLICredential(preferFile: preferFile)
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

        // Refresh expired token before identifying account
        if credential.isExpired {
            Log.profiles.info("detectCLI: token expired, refreshing first...")
            if let refreshed = try? await ClaudeAPIService.refreshToken(credential) {
                credential = refreshed
            }
        }

        guard claudeEnabled, !Task.isCancelled else { return }

        guard let apiProfile = try? await ClaudeAPIService.fetchProfile(credential: credential) else {
            Log.profiles.warning("detectCLI: fetchProfile failed")
            if !Task.isCancelled, !hasAnyAuthenticated {
                let target = profiles.first { !authenticatedProfileIDs.contains($0.id) } ?? profiles[0]
                saveAndActivate(credential: credential, profileID: target.id)
            }
            return
        }

        guard claudeEnabled, !Task.isCancelled else { return }

        credential.accountUUID = apiProfile.uuid
        Log.profiles.info("detectCLI: account=\(apiProfile.uuid) name=\(apiProfile.displayName)")

        // Match by accountUUID
        for profile in profiles {
            if let stored = cachedCredentials[profile.id],
               stored.accountUUID == apiProfile.uuid {
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
                cachedCredentials[profile.id] = updated
                try? ProfileStore.saveCredentialModel(updated, for: profile.id)
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
        cachedCredentials[profileID] = credential
        try? ProfileStore.saveCredentialModel(credential, for: profileID)
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
                    self.cachedCredentials[profile.id] = updated
                    try? ProfileStore.saveCredentialModel(updated, for: profile.id)
                    Log.profiles.info("backfill: set accountUUID for '\(profile.name)' → \(apiProfile.uuid)")
                }
            }
            backfillTasks.append(task)
        }
    }

    static func migrateCredentialStorage(
        toFileBased: Bool,
        cachedCredentials: [UUID: Credential],
        saveStorageMode: (Bool) -> Void,
        saveCredential: (Credential, UUID) throws -> Void,
        deleteKeychainCredential: (UUID) throws -> Void,
        deleteFileCredentials: () -> Void,
        logSaveFailure: (UUID, Error) -> Void
    ) {
        saveStorageMode(toFileBased)

        var migratedProfileIDs = Set<UUID>()
        for (profileID, credential) in cachedCredentials {
            do {
                try saveCredential(credential, profileID)
                migratedProfileIDs.insert(profileID)
            } catch {
                logSaveFailure(profileID, error)
            }
        }

        if toFileBased {
            // Skip keychain deletion — accessing SecItemDelete triggers
            // the same macOS password prompts we're trying to avoid.
            // Stale keychain entries are harmless in file-based mode.
        } else if !cachedCredentials.isEmpty,
                  migratedProfileIDs.count == cachedCredentials.count {
            deleteFileCredentials()
        }
    }

    private func migrateCredentialStorage(toFileBased: Bool) {
        Log.profiles.info("migrateCredentialStorage: toFileBased=\(toFileBased), \(cachedCredentials.count) credentials")

        Self.migrateCredentialStorage(
            toFileBased: toFileBased,
            cachedCredentials: cachedCredentials,
            saveStorageMode: { ProfileStore.saveFileBasedStorage($0) },
            saveCredential: { credential, profileID in
                try ProfileStore.saveCredentialModel(credential, for: profileID)
            },
            deleteKeychainCredential: { profileID in
                try KeychainService.delete(for: profileID)
            },
            deleteFileCredentials: {
                FileCredentialStore.deleteAll()
            },
            logSaveFailure: { profileID, error in
                Log.profiles.error("migrateCredentialStorage: failed to save \(profileID): \(error)")
            }
        )

        if toFileBased, let activeID = cliActiveProfileID,
           let credential = cachedCredentials[activeID],
           !ClaudeCodeSyncService.cliCredentialFileExists() {
            ClaudeCodeSyncService.writeCLICredential(credential, preferFile: true)
        }
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

        let coordinator = UsageRefreshCoordinator(
            profileID: profileID,
            readOnly: false,
            credentialProvider: { [weak self] in
                self?.cachedCredentials[profileID]
            },
            onCredentialRefreshed: { [weak self] refreshed in
                guard self?.claudeEnabled == true else { return }
                Log.profiles.info("[\(profileID)] credential refreshed, saving to app keychain...")
                self?.cachedCredentials[profileID] = refreshed
                try? ProfileStore.saveCredentialModel(refreshed, for: profileID)
                if self?.cliActiveProfileID == profileID {
                    let preferFile = self?.fileBasedStorage ?? false
                    Log.profiles.info("[\(profileID)] is CLI-active, writing back to CLI credential store...")
                    ClaudeCodeSyncService.writeCLICredential(refreshed, preferFile: preferFile)
                }
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
        cancellables[profileID] = [usageSink, errorSink, lastSuccessSink]
        coordinators[profileID] = coordinator
        coordinator.startPolling()
    }

    private func teardownCoordinator(for profileID: UUID) {
        coordinators[profileID]?.stopPolling()
        coordinators.removeValue(forKey: profileID)
        cancellables.removeValue(forKey: profileID)
        allUsageData.removeValue(forKey: profileID)
        allErrors.removeValue(forKey: profileID)
        allLastSuccess.removeValue(forKey: profileID)
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
                coordinator.refresh()
            }
        }
        if codexEnabled {
            codexCoordinator.refresh()
        }
    }

    func activateForCLI(profileID: UUID) {
        guard let credential = cachedCredentials[profileID] else { return }
        Log.profiles.info("activateForCLI: switching to \(profileID), writing to CLI credential store...")
        ClaudeCodeSyncService.writeCLICredential(credential, preferFile: fileBasedStorage)
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
        try? ProfileStore.deleteCredential(for: id)
        refreshAuthenticatedIDs()
    }

    func removeCredential(for profileID: UUID) {
        teardownCoordinator(for: profileID)
        try? ProfileStore.deleteCredential(for: profileID)
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
