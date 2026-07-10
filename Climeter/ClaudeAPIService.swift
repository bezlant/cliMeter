import Foundation

enum ClaudeAPIService {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func fetchUsage(credential: Credential) async throws -> UsageData {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Log.api.info("fetchUsage: GET /api/oauth/usage")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        Log.api.info("fetchUsage: HTTP \(httpResponse.statusCode)")
        guard httpResponse.statusCode == 200 else {
            logErrorResponse(httpResponse, data: data, label: "fetchUsage")
            if httpResponse.statusCode == 429 {
                throw ClaudeAPIError.rateLimited(retryAfter: retryAfterDelay(from: httpResponse))
            }
            throw ClaudeAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let usageData = try decoder.decode(UsageData.self, from: data)
            return usageData
        } catch {
            Log.api.error("fetchUsage: decode error: \(error)")
            throw ClaudeAPIError.decodingError(error)
        }
    }

    static func refreshSelfOwnedToken(_ credential: Credential) async throws -> Credential {
        let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.api.info("refreshToken: POST /v1/oauth/token")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        Log.api.info("refreshToken: HTTP \(httpResponse.statusCode)")
        guard httpResponse.statusCode == 200 else {
            logErrorResponse(httpResponse, data: data, label: "refreshToken")
            throw ClaudeAPIError.tokenRefreshFailed(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        Log.api.info("refreshToken: success, new token expires in \(Int(expiresIn))s")
        var refreshed = credential
        refreshed.accessToken = accessToken
        refreshed.refreshToken = refreshToken
        refreshed.expiresAt = Date.now.addingTimeInterval(expiresIn)
        return refreshed
    }

    struct AccountProfile {
        let uuid: String
        let displayName: String
    }

    static func fetchProfile(credential: Credential) async throws -> AccountProfile {
        let url = URL(string: "https://api.anthropic.com/api/oauth/profile")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        Log.api.info("fetchProfile: GET /api/oauth/profile")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        Log.api.info("fetchProfile: HTTP \(httpResponse.statusCode)")
        guard httpResponse.statusCode == 200 else {
            logErrorResponse(httpResponse, data: data, label: "fetchProfile")
            throw ClaudeAPIError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let uuid = account["uuid"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let displayName = account["full_name"] as? String
            ?? account["display_name"] as? String
            ?? "Account"

        return AccountProfile(uuid: uuid, displayName: displayName)
    }

    /// Log diagnostics for non-200 HTTP responses (Retry-After header + body
    /// snippet). Particularly useful for /api/oauth/usage 429s which Anthropic
    /// is known to mishandle (see anthropics/claude-code#30930, #31637, #31021).
    private static func logErrorResponse(_ response: HTTPURLResponse, data: Data, label: String) {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After") ?? "absent"
        let bodySnippet: String = {
            guard !data.isEmpty,
                  let str = String(data: data, encoding: .utf8) else {
                return "(empty)"
            }
            return str.count > 500 ? String(str.prefix(500)) + "…" : str
        }()
        Log.api.warning("\(label): HTTP \(response.statusCode) Retry-After=\(retryAfter) body=\(bodySnippet)")
    }

    private static func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return max(0, seconds)
    }

    static func startSession(credential: Credential) async {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Log.api.info("startSession: POST /v1/messages (auto-start)")
        _ = try? await URLSession.shared.data(for: request)
    }
}

enum ClaudeAPIError: Error {
    case invalidCredential
    case invalidResponse
    case httpError(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case decodingError(Error)
    case tokenRefreshFailed(Int)
}
