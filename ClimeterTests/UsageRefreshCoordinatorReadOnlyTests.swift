import XCTest
@testable import Climeter

@MainActor
final class UsageRefreshCoordinatorReadOnlyTests: XCTestCase {
    private func cred(_ secs: Double, _ t: String) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"\#(t)","refreshToken":"r","expiresAt":\#((Date.now.timeIntervalSince1970 + secs) * 1000)}}"#)!
    }

    private func cred(_ secs: Double, _ token: String, accountUUID: String) -> Credential {
        Credential(jsonString: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":\#((Date.now.timeIntervalSince1970 + secs) * 1000),"accountUUID":"\#(accountUUID)"}}"#)!
    }

    private func make(cached: Credential?,
                      keychain: @escaping () -> Credential?,
                      onCache: @escaping (Credential) -> Void = { _ in },
                      fetch: @escaping (Credential) async throws -> UsageData,
                      refresh: @escaping (Credential) async throws -> Credential) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(profileID: UUID(),
                                readOnly: true,
                                credentialProvider: { cached },
                                keychainReader: keychain,
                                onCredentialCached: onCache,
                                onAutoStart: nil,
                                usageFetcher: fetch,
                                refresher: refresh)
    }

    private func makeSelfOwned(cached: Credential?,
                               fetch: @escaping (Credential) async throws -> UsageData,
                               refresh: @escaping (Credential) async throws -> Credential = { $0 }) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(profileID: UUID(),
                                readOnly: false,
                                credentialProvider: { cached },
                                onAutoStart: nil,
                                usageFetcher: fetch,
                                refresher: refresh)
    }

    func test_expiredCached_freshKeychain_fetchesNoRefresh() async {
        var refreshed = false
        var token: String?
        var cachedToken: String?
        let c = make(cached: cred(60, "old"),
                     keychain: { self.cred(3600, "fresh") },
                     onCache: { cachedToken = $0.accessToken },
                     fetch: {
                         token = $0.accessToken
                         return .empty
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(cachedToken, "fresh")
    }

    func test_bothExpired_staleNoRefreshNoFetch() async {
        var refreshed = false
        var fetched = false
        let c = make(cached: cred(60, "old"),
                     keychain: { self.cred(60, "old2") },
                     fetch: { _ in
                         fetched = true
                         return .empty
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)
        XCTAssertFalse(fetched)
        XCTAssertTrue(c.isStale)
    }

    func test_bothExpired_throttlesRepeatedKeychainReadsWhileStale() async {
        var reads = 0
        let c = make(cached: cred(60, "old"),
                     keychain: {
                         reads += 1
                         return self.cred(60, "old2")
                     },
                     fetch: { _ in
                         XCTFail("expired tokens should not fetch")
                         return .empty
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        await c.refreshForTest()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(c.isStale)
    }

    func test_forcedRefreshBypassesStaleKeychainReadThrottle() async {
        var reads = 0
        var fetchedToken: String?
        let c = make(cached: cred(60, "old"),
                     keychain: {
                         reads += 1
                         return reads == 1 ? self.cred(60, "still-old") : self.cred(3600, "fresh")
                     },
                     fetch: {
                         fetchedToken = $0.accessToken
                         return .empty
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        await c.refreshForTest()
        await c.refreshForTest(forceKeychainReread: true)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(fetchedToken, "fresh")
        XCTAssertFalse(c.isStale)
    }

    func test_401_rereadsKeychainOnce_noRefresh() async {
        var refreshed = false
        var reads = 0
        var calls = 0
        var cachedToken: String?
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: {
                         reads += 1
                         return self.cred(3600, "fromKeychain")
                     },
                     onCache: { cachedToken = $0.accessToken },
                     fetch: { _ in
                         calls += 1
                         if calls == 1 { throw ClaudeAPIError.httpError(401) }
                         return .empty
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cachedToken, "fromKeychain")
    }

    func test_401_sameAccessTokenDifferentMetadata_staleNoRetryNoRefresh() async {
        var refreshed = false
        var reads = 0
        var calls = 0
        let c = make(cached: cred(3600, "same-token", accountUUID: "A"),
                     keychain: {
                         reads += 1
                         return self.cred(3600, "same-token", accountUUID: "B")
                     },
                     fetch: { _ in
                         calls += 1
                         throw ClaudeAPIError.httpError(401)
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(c.isStale)
    }

    func test_refreshWhileReadOnlyLoadingSkipsSecondFetch() async {
        var refreshed = false
        var calls = 0
        var resumeFetch: CheckedContinuation<UsageData, Error>?
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { nil },
                     fetch: { _ in
                         calls += 1
                         return try await withCheckedThrowingContinuation { continuation in
                             resumeFetch = continuation
                         }
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        c.refresh()
        await Task.yield()
        XCTAssertTrue(c.isLoading)
        c.refresh()
        XCTAssertEqual(calls, 1)
        resumeFetch?.resume(returning: .empty)
        await Task.yield()
        XCTAssertFalse(refreshed)
        XCTAssertFalse(c.isLoading)
    }

    func test_stopPollingDuringReadOnlyFetchClearsLoadingSoRetryCanFetch() async {
        var calls = 0
        var resumeFirstFetch: CheckedContinuation<UsageData, Error>?
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { nil },
                     fetch: { _ in
                         calls += 1
                         if calls == 1 {
                             return try await withCheckedThrowingContinuation { continuation in
                                 resumeFirstFetch = continuation
                             }
                         }
                         return .empty
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })

        c.refresh()
        await Task.yield()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(c.isLoading)

        c.stopPolling()
        XCTAssertFalse(c.isLoading)

        c.refresh()
        await Task.yield()
        XCTAssertEqual(calls, 2)
        resumeFirstFetch?.resume(throwing: CancellationError())
    }

    func test_stoppedSelfOwnedTaskCannotClearNewerRefreshLoadingState() async {
        var continuations: [CheckedContinuation<UsageData, Error>] = []
        var calls = 0
        let c = makeSelfOwned(cached: cred(3600, "cachedValid"),
                              fetch: { _ in
                                  calls += 1
                                  return try await withCheckedThrowingContinuation { continuation in
                                      continuations.append(continuation)
                                  }
                              })

        c.refresh()
        await Task.yield()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(c.isLoading)

        c.stopPolling()
        XCTAssertFalse(c.isLoading)

        c.refresh()
        await Task.yield()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(c.isLoading)

        continuations[0].resume(returning: .empty)
        await Task.yield()
        XCTAssertTrue(c.isLoading)
        XCTAssertNil(c.usageData)

        continuations[1].resume(returning: .empty)
        await Task.yield()
        XCTAssertFalse(c.isLoading)
        XCTAssertNotNil(c.usageData)
    }

    func test_401Retry429PreservesStaleAndRateLimitError() async {
        var refreshed = false
        var calls = 0
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { self.cred(3600, "fromKeychain") },
                     fetch: { _ in
                         calls += 1
                         throw calls == 1 ? ClaudeAPIError.httpError(401) : ClaudeAPIError.httpError(429)
                     },
                     refresh: { _ in
                         refreshed = true
                         throw ClaudeAPIError.invalidResponse
                     })
        await c.refreshForTest()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(c.isStale)
        XCTAssertEqual(c.errorMessage, "Rate limited — retrying soon")
    }

    func test_429WithExistingUsageKeepsDataAndPublishesRateLimitError() async {
        var shouldFail = false
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { nil },
                     fetch: { _ in
                         if shouldFail { throw ClaudeAPIError.httpError(429) }
                         return .empty
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        await c.refreshForTest()
        shouldFail = true
        await c.refreshForTest()
        XCTAssertNotNil(c.usageData)
        XCTAssertTrue(c.isStale)
        XCTAssertEqual(c.errorMessage, "Rate limited — retrying soon")
    }

    func test_rateLimitedRetryAfterSuppressesImmediateManualRetry() async {
        var calls = 0
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { nil },
                     fetch: { _ in
                         calls += 1
                         throw ClaudeAPIError.rateLimited(retryAfter: 300)
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })

        await c.refreshForTest()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.errorMessage, "Rate limited — retrying soon")

        await c.refreshForTest()
        XCTAssertEqual(calls, 1)
    }

    func test_cancelledReadOnlyFetchDoesNotPublish() async {
        var resumeFetch: CheckedContinuation<UsageData, Error>?
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { nil },
                     fetch: { _ in
                         try await withCheckedThrowingContinuation { continuation in
                             resumeFetch = continuation
                         }
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        c.refresh()
        await Task.yield()
        c.stopPolling()
        resumeFetch?.resume(returning: .empty)
        await Task.yield()
        XCTAssertNil(c.usageData)
    }

    func test_cancelledReadOnly401RetryDoesNotCacheOrPublish() async {
        var cachedToken: String?
        var resumeFirstFetch: CheckedContinuation<UsageData, Error>?
        var calls = 0
        let c = make(cached: cred(3600, "cachedValid"),
                     keychain: { self.cred(3600, "fromKeychain") },
                     onCache: { cachedToken = $0.accessToken },
                     fetch: { _ in
                         calls += 1
                         return try await withCheckedThrowingContinuation { continuation in
                             resumeFirstFetch = continuation
                         }
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        c.refresh()
        await Task.yield()
        c.stopPolling()
        resumeFirstFetch?.resume(throwing: ClaudeAPIError.httpError(401))
        await Task.yield()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(cachedToken)
        XCTAssertNil(c.usageData)
    }

    func test_cancelledReadOnlyKeychainReadDoesNotCacheFetchOrMarkStale() async {
        var cachedToken: String?
        var keychainRead = false
        var fetched = false
        let c = make(cached: cred(60, "expired"),
                     keychain: {
                         keychainRead = true
                         return self.cred(3600, "fresh")
                     },
                     onCache: { cachedToken = $0.accessToken },
                     fetch: { _ in
                         fetched = true
                         return .empty
                     },
                     refresh: { _ in throw ClaudeAPIError.invalidResponse })
        c.refresh()
        c.stopPolling()
        await Task.yield()
        XCTAssertFalse(keychainRead)
        XCTAssertNil(cachedToken)
        XCTAssertFalse(fetched)
        XCTAssertFalse(c.isStale)
    }
}

extension UsageData {
    static var empty: UsageData {
        try! JSONDecoder().decode(UsageData.self, from: Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":0}}"#.utf8))
    }
}
