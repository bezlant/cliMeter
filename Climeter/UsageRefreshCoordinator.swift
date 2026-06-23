import Foundation
import SwiftUI

class UsageRefreshCoordinator: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var lastSuccessAt: Date?
    @Published var isStale: Bool = false

    let profileID: UUID
    let readOnly: Bool
    private let credentialProvider: () -> Credential?
    private let keychainReader: (() -> Credential?)?
    private let onCredentialRefreshed: ((Credential) -> Void)?
    private let onCredentialCached: ((Credential) -> Void)?
    private let usageFetcher: (Credential) async throws -> UsageData
    private let refresher: (Credential) async throws -> Credential
    private var timer: Timer?
    private var activeTask: Task<Void, Never>?
    static let baseInterval: TimeInterval = 180.0
    private var currentInterval: TimeInterval = UsageRefreshCoordinator.baseInterval
    // IMPORTANT: max backoff must stay high — Anthropic's /api/oauth/usage
    // endpoint rate-limits aggressively (see anthropics/claude-code#31637)
    // and stays locked out for 30+ minutes even at 5-minute retry intervals.
    private let maxInterval: TimeInterval = 900.0

    private var lastAutoStartResetTime: Date?
    private let onAutoStart: ((Credential) -> Void)?

    init(profileID: UUID,
         readOnly: Bool,
         credentialProvider: @escaping () -> Credential?,
         keychainReader: (() -> Credential?)? = nil,
         onCredentialRefreshed: ((Credential) -> Void)? = nil,
         onCredentialCached: ((Credential) -> Void)? = nil,
         onAutoStart: ((Credential) -> Void)? = nil,
         usageFetcher: @escaping (Credential) async throws -> UsageData = { try await ClaudeAPIService.fetchUsage(credential: $0) },
         refresher: @escaping (Credential) async throws -> Credential = { try await ClaudeAPIService.refreshToken($0) }) {
        self.profileID = profileID
        self.readOnly = readOnly
        self.credentialProvider = credentialProvider
        self.keychainReader = keychainReader
        self.onCredentialRefreshed = onCredentialRefreshed
        self.onCredentialCached = onCredentialCached
        self.onAutoStart = onAutoStart
        self.usageFetcher = usageFetcher
        self.refresher = refresher
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.refresh()
            self?.scheduleNextPoll()
        }
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        // Add ±10% jitter to avoid two coordinators staying phase-locked
        // and colliding on every poll cycle.
        let jitter = Double.random(in: 0.9...1.1)
        let interval = currentInterval * jitter
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
            self?.scheduleNextPoll()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        activeTask?.cancel()
        activeTask = nil
    }

    func refresh() {
        guard !isLoading else {
            Log.coordinator.debug("[\(self.profileID)] refresh skipped — already loading")
            return
        }

        if readOnly {
            isLoading = true
            activeTask = Task { @MainActor in
                defer { self.isLoading = false }
                await self.runReadOnlyCycle()
            }
            return
        }

        Log.coordinator.info("[\(self.profileID)] poll cycle start (interval: \(self.currentInterval)s)")

        guard var credential = credentialProvider() else {
            Log.coordinator.warning("[\(self.profileID)] no credential available, skipping poll")
            return
        }

        let expiresIn = credential.expiresAt.timeIntervalSinceNow
        Log.coordinator.info("[\(self.profileID)] token expires in \(Int(expiresIn))s, isExpired=\(credential.isExpired)")

        isLoading = true

        activeTask = Task { @MainActor in
            defer { self.isLoading = false }

            if credential.isExpired {
                Log.coordinator.info("[\(self.profileID)] token expired, starting recovery...")
                do {
                    credential = try await self.recoverCredential(credential)
                    guard !Task.isCancelled else { return }
                    Log.coordinator.info("[\(self.profileID)] token recovery succeeded")
                } catch {
                    guard !Task.isCancelled else { return }
                    Log.coordinator.error("[\(self.profileID)] token recovery failed: \(error)")
                    self.errorMessage = Self.describeError(error, context: "token refresh")
                    return
                }
            }

            do {
                let fetchedData = try await self.usageFetcher(credential)
                guard !Task.isCancelled else { return }
                Log.coordinator.info("[\(self.profileID)] usage fetch OK — 5h: \(fetchedData.fiveHour.utilization)%")
                self.usageData = fetchedData
                self.errorMessage = nil
                self.lastSuccessAt = Date()
                self.isStale = false
                self.checkAutoStart(credential: credential, usage: fetchedData)
                self.stepDownBackoff()
            } catch {
                guard !Task.isCancelled else { return }
                guard case .httpError(401) = error as? ClaudeAPIError else {
                    Log.coordinator.error("[\(self.profileID)] usage fetch failed: \(error)")
                    self.handleFetchError(error)
                    return
                }
                Log.coordinator.warning("[\(self.profileID)] got 401, attempting recovery...")
                do {
                    credential = try await self.recoverCredential(credential)
                    guard !Task.isCancelled else { return }
                    let fetchedData = try await self.usageFetcher(credential)
                    guard !Task.isCancelled else { return }
                    Log.coordinator.info("[\(self.profileID)] retry after 401 succeeded — 5h: \(fetchedData.fiveHour.utilization)%")
                    self.usageData = fetchedData
                    self.errorMessage = nil
                    self.lastSuccessAt = Date()
                    self.isStale = false
                    self.checkAutoStart(credential: credential, usage: fetchedData)
                    self.stepDownBackoff()
                } catch {
                    guard !Task.isCancelled else { return }
                    Log.coordinator.error("[\(self.profileID)] retry after 401 failed: \(error)")
                    self.handleFetchError(error)
                }
            }
        }
    }

    func refreshForTest() async {
        await runReadOnlyCycle()
    }

    @MainActor
    private func runReadOnlyCycle() async {
        guard !Task.isCancelled else { return }
        let cached = credentialProvider()
        var action = CLICredentialPolicy.action(cached: cached, keychain: nil, now: Date.now)
        if action == .rereadKeychain {
            guard !Task.isCancelled else { return }
            action = CLICredentialPolicy.action(cached: cached, keychain: keychainReader?(), now: Date.now)
        }
        guard !Task.isCancelled else { return }

        switch action {
        case .fetchUsage(let credential):
            await fetchReadOnly(credential, fromKeychain: false)
        case .fetchUsageAndCache(let credential):
            guard !Task.isCancelled else { return }
            onCredentialCached?(credential)
            await fetchReadOnly(credential, fromKeychain: true)
        case .rereadKeychain, .showStale:
            guard !Task.isCancelled else { return }
            isStale = true
        }
    }

    @MainActor
    private func fetchReadOnly(_ credential: Credential, fromKeychain: Bool) async {
        do {
            let data = try await usageFetcher(credential)
            guard !Task.isCancelled else { return }
            publishSuccess(data, credential: credential, fromKeychain: fromKeychain)
        } catch ClaudeAPIError.httpError(401) {
            guard !Task.isCancelled else { return }
            guard let keychainCredential = keychainReader?(),
                  keychainCredential.accessToken != credential.accessToken,
                  !keychainCredential.isExpired else {
                guard !Task.isCancelled else { return }
                isStale = true
                return
            }
            guard !Task.isCancelled else { return }
            onCredentialCached?(keychainCredential)
            do {
                let data = try await usageFetcher(keychainCredential)
                guard !Task.isCancelled else { return }
                publishSuccess(data, credential: keychainCredential, fromKeychain: true)
            } catch {
                guard !Task.isCancelled else { return }
                isStale = true
                handleFetchError(error)
            }
        } catch {
            guard !Task.isCancelled else { return }
            isStale = true
            handleFetchError(error)
            if usageData == nil {
                errorMessage = Self.describeError(error, context: "fetch")
            }
        }
    }

    @MainActor
    private func publishSuccess(_ data: UsageData, credential: Credential, fromKeychain: Bool) {
        usageData = data
        errorMessage = nil
        lastSuccessAt = Date()
        isStale = false
        if fromKeychain {
            checkAutoStart(credential: credential, usage: data)
        }
        stepDownBackoff()
    }

    /// Attempt to refresh the credential and write it back through the owner.
    private func recoverCredential(_ credential: Credential) async throws -> Credential {
        do {
            Log.coordinator.info("[\(self.profileID)] attempting token refresh via API...")
            let refreshed = try await refresher(credential)
            try Task.checkCancellation()
            Log.coordinator.info("[\(self.profileID)] token refresh succeeded, writing back...")
            onCredentialRefreshed?(refreshed)
            return refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            Log.coordinator.warning("[\(self.profileID)] token refresh failed: \(error)")
            throw error
        }
    }

    private func checkAutoStart(credential: Credential, usage: UsageData) {
        guard onAutoStart != nil,
              usage.fiveHour.utilization == 0 else {
            lastAutoStartResetTime = nil
            return
        }
        guard let resetTime = usage.fiveHour.resetsAt else { return }
        guard lastAutoStartResetTime != resetTime else { return }
        lastAutoStartResetTime = resetTime
        onAutoStart?(credential)
    }

    private func handleFetchError(_ error: Error) {
        let is429 = (error as? ClaudeAPIError).map {
            if case .httpError(429) = $0 { return true }
            return false
        } ?? false

        if is429 {
            currentInterval = min(currentInterval * 2, maxInterval)
            Log.coordinator.info("[\(self.profileID)] backoff increased → \(self.currentInterval)s")
            scheduleNextPoll()
        }

        if usageData == nil {
            errorMessage = Self.describeError(error, context: "fetch")
        }
    }

    /// Halve the polling interval after a successful fetch instead of jumping
    /// straight back to baseInterval. The /api/oauth/usage endpoint frequently
    /// returns 429 again immediately when we drop back to the base interval
    /// after a single success, so we step down gradually.
    private func stepDownBackoff() {
        guard currentInterval > Self.baseInterval else { return }
        currentInterval = max(currentInterval / 2, Self.baseInterval)
        Log.coordinator.info("[\(self.profileID)] backoff step-down → \(self.currentInterval)s")
        scheduleNextPoll()
    }

    private static func describeError(_ error: Error, context: String) -> String {
        guard let apiError = error as? ClaudeAPIError else {
            return "Network error"
        }
        switch apiError {
        case .httpError(401), .tokenRefreshFailed(401):
            return "Session expired — run /login"
        case .tokenRefreshFailed(400):
            return "Token invalid — run /login"
        case .httpError(429):
            return "Rate limited — retrying soon"
        case .httpError(let code), .tokenRefreshFailed(let code):
            return "HTTP \(code)"
        case .invalidResponse:
            return "Bad response"
        case .decodingError:
            return "Unexpected data format"
        case .invalidCredential:
            return "Invalid credential"
        }
    }

    deinit {
        stopPolling()
    }
}
