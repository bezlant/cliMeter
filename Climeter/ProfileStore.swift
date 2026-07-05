import Foundation

enum ProfileStore {
    private static let profilesKey = "profiles"
    private static let activeProfileIDKey = "activeProfileID"
    private static let cliActiveProfileIDKey = "cliActiveProfileID"
    private static let autoSwitchEnabledKey = "autoSwitchEnabled"
    private static let autoSwitchThresholdKey = "autoSwitchThreshold"
    private static let claudeEnabledKey = "claudeEnabled"
    private static let codexEnabledKey = "codexEnabled"
    private static let peakHoursEnabledKey = "peakHoursEnabled"
    private static let accountMetaKey = "accountMeta"
    private static let authenticatedKey = "authenticatedProfiles"
    private static let defaults = UserDefaults.standard

    static func loadProfiles() -> [Profile] {
        guard let data = defaults.data(forKey: profilesKey) else {
            return []
        }

        do {
            let profiles = try JSONDecoder().decode([Profile].self, from: data)
            return profiles
        } catch {
            return []
        }
    }

    static func saveProfiles(_ profiles: [Profile]) {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: profilesKey)
        } catch {
            // Silent failure
        }
    }

    static func loadActiveProfileID() -> UUID? {
        guard let uuidString = defaults.string(forKey: activeProfileIDKey) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    static func saveActiveProfileID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: activeProfileIDKey)
    }

    static func loadCLIActiveProfileID() -> UUID? {
        guard let uuidString = defaults.string(forKey: cliActiveProfileIDKey) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    static func saveCLIActiveProfileID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: cliActiveProfileIDKey)
        } else {
            defaults.removeObject(forKey: cliActiveProfileIDKey)
        }
    }

    // MARK: - Auto-Switch Settings

    static func loadAutoSwitchEnabled() -> Bool {
        // Default to off if never set
        if defaults.object(forKey: autoSwitchEnabledKey) == nil { return false }
        return defaults.bool(forKey: autoSwitchEnabledKey)
    }

    static func saveAutoSwitchEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoSwitchEnabledKey)
    }

    static func loadAutoSwitchThreshold() -> Double {
        let value = defaults.double(forKey: autoSwitchThresholdKey)
        return value > 0 ? value : 95.0
    }

    static func saveAutoSwitchThreshold(_ threshold: Double) {
        defaults.set(threshold, forKey: autoSwitchThresholdKey)
    }

    // MARK: - Claude Settings

    static func loadClaudeEnabled() -> Bool {
        defaults.object(forKey: claudeEnabledKey) as? Bool ?? true
    }

    static func saveClaudeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: claudeEnabledKey)
    }

    // MARK: - Peak Hours Settings

    static func loadPeakHoursEnabled() -> Bool {
        defaults.object(forKey: peakHoursEnabledKey) as? Bool ?? true
    }

    static func savePeakHoursEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: peakHoursEnabledKey)
    }

    // MARK: - Codex Settings

    static func loadCodexEnabled() -> Bool {
        defaults.object(forKey: codexEnabledKey) as? Bool ?? true
    }

    static func saveCodexEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: codexEnabledKey)
    }

    // Raw string credential operations for Climeter-owned credentials.
    static func saveCredential(_ sessionKey: String, for profileID: UUID) throws {
        try KeychainService.save(sessionKey, for: profileID)
    }

    static func loadCredential(for profileID: UUID) throws -> String? {
        try KeychainService.read(for: profileID)
    }

    static func deleteCredential(for profileID: UUID) throws {
        try KeychainService.delete(for: profileID)
    }

    static func deleteCredentialFromAllStores(for profileID: UUID) {
        try? KeychainService.delete(for: profileID)
        try? FileCredentialStore.delete(for: profileID)
    }

    // Credential model convenience methods
    static func saveCredentialModel(_ credential: Credential, for profileID: UUID) throws {
        try saveCredential(credential.toJSONString(), for: profileID)
    }

    static func loadCredentialModel(for profileID: UUID) -> Credential? {
        guard let raw = try? loadCredential(for: profileID) else { return nil }
        return Credential(jsonString: raw)
    }

    // MARK: - Account Metadata

    static func saveAccountMetadata(_ cred: Credential, for id: UUID) {
        var dict = defaults.dictionary(forKey: accountMetaKey) as? [String: [String: String]] ?? [:]
        var e = dict[id.uuidString] ?? [:]
        if let v = cred.accountUUID { e["uuid"] = v }
        if let v = cred.subscriptionType { e["subscriptionType"] = v }
        if let v = cred.rateLimitTier { e["rateLimitTier"] = v }
        dict[id.uuidString] = e
        defaults.set(dict, forKey: accountMetaKey)
        markAuthenticated(id)
    }

    static func accountUUID(for id: UUID) -> String? {
        (defaults.dictionary(forKey: accountMetaKey) as? [String: [String: String]])?[id.uuidString]?["uuid"]
    }

    static func clearAccountMetadata(_ id: UUID) {
        var dict = defaults.dictionary(forKey: accountMetaKey) as? [String: [String: String]] ?? [:]
        dict.removeValue(forKey: id.uuidString)
        defaults.set(dict, forKey: accountMetaKey)
    }

    static func markAuthenticated(_ id: UUID) {
        var s = Set(defaults.stringArray(forKey: authenticatedKey) ?? [])
        s.insert(id.uuidString)
        defaults.set(Array(s), forKey: authenticatedKey)
    }

    static func clearAuthenticated(_ id: UUID) {
        var s = Set(defaults.stringArray(forKey: authenticatedKey) ?? [])
        s.remove(id.uuidString)
        defaults.set(Array(s), forKey: authenticatedKey)
    }

    static func authenticatedMarkers() -> Set<UUID> {
        Set((defaults.stringArray(forKey: authenticatedKey) ?? []).compactMap(UUID.init))
    }
}
