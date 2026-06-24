import Foundation

/// Pure decision for a read-only (cliSynced) profile's poll cycle.
/// Deliberately NO `refresh` case — Climeter must never rotate the shared token.
enum CLIRefreshAction: Equatable {
    case fetchUsage(Credential)          // cached access token still valid
    case fetchUsageAndCache(Credential)  // use freshly-read keychain token, update cache
    case rereadKeychain                  // need a keychain read to decide
    case showStale                       // nothing usable; keep last usage, mark stale
}

enum CLICredentialPolicy {
    static func action(cached: Credential?, keychain: Credential?, now: Date) -> CLIRefreshAction {
        if let cached, !cached.isExpired(now: now) { return .fetchUsage(cached) }
        guard let keychain else { return .rereadKeychain }
        return keychain.isExpired(now: now) ? .showStale : .fetchUsageAndCache(keychain)
    }
}
