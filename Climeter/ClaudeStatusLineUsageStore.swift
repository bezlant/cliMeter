import Combine
import Foundation

enum ClaudeStatusLineUsageError: Error, Equatable {
    case missingFile
    case incompleteWindows
    case unsupportedSchema(Int)
    case invalidFile
}

struct ClaudeStatusLineUsageSnapshot {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let updatedAt: Date

    var usageData: UsageData? {
        guard let fiveHour, let sevenDay else { return nil }
        return UsageData(fiveHour: fiveHour, sevenDay: sevenDay)
    }
}

final class ClaudeStatusLineUsageStore: ObservableObject {
    @Published private(set) var usageData: UsageData?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var isStale = false

    static let pollInterval: TimeInterval = 1
    static let staleThreshold: TimeInterval = 10 * 60

    private let fileURL: URL
    private let readData: (URL) throws -> Data
    private var snapshot: ClaudeStatusLineUsageSnapshot?
    private var timer: Timer?

    init(
        fileURL: URL = ClaudeStatusLineUsageStore.defaultFileURL(),
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.fileURL = fileURL
        self.readData = readData
    }

    deinit {
        stopPolling()
    }

    func startPolling() {
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(now: Date = .now) {
        do {
            let payload = try JSONDecoder().decode(FilePayload.self, from: readData(fileURL))
            guard payload.schemaVersion == 1 else {
                throw ClaudeStatusLineUsageError.unsupportedSchema(payload.schemaVersion)
            }

            let incoming = try Self.snapshot(from: payload)
            snapshot = ClaudeStatusLineUsageSnapshot(
                fiveHour: incoming.fiveHour ?? snapshot?.fiveHour,
                sevenDay: incoming.sevenDay ?? snapshot?.sevenDay,
                updatedAt: incoming.updatedAt
            )

            guard let usage = snapshot?.usageData else {
                usageData = nil
                throw ClaudeStatusLineUsageError.incompleteWindows
            }

            usageData = usage
            lastSuccessAt = snapshot?.updatedAt
            errorMessage = nil
            updateStaleness(now: now)
        } catch {
            errorMessage = Self.message(for: Self.normalizedError(error))
            updateStaleness(now: now)
        }
    }

    static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Climeter", isDirectory: true)
            .appendingPathComponent("claude-usage.json")
    }
}

private extension ClaudeStatusLineUsageStore {
    struct FilePayload: Decodable {
        let schemaVersion: Int
        let updatedAt: TimeInterval
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case updatedAt = "updated_at"
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: WindowPayload?
        let sevenDay: WindowPayload?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct WindowPayload: Decodable {
        let usedPercentage: Double
        let resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    static func snapshot(from payload: FilePayload) throws -> ClaudeStatusLineUsageSnapshot {
        guard payload.updatedAt.isFinite else {
            throw ClaudeStatusLineUsageError.invalidFile
        }

        return ClaudeStatusLineUsageSnapshot(
            fiveHour: try usageWindow(from: payload.rateLimits.fiveHour),
            sevenDay: try usageWindow(from: payload.rateLimits.sevenDay),
            updatedAt: Date(timeIntervalSince1970: payload.updatedAt)
        )
    }

    static func usageWindow(from payload: WindowPayload?) throws -> UsageWindow? {
        guard let payload else { return nil }
        guard payload.usedPercentage.isFinite, 0...100 ~= payload.usedPercentage else {
            throw ClaudeStatusLineUsageError.invalidFile
        }
        guard payload.resetsAt?.isFinite != false else {
            throw ClaudeStatusLineUsageError.invalidFile
        }

        return UsageWindow(
            utilization: payload.usedPercentage,
            resetsAt: payload.resetsAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    static func message(for error: Error) -> String {
        switch error as? ClaudeStatusLineUsageError {
        case .missingFile:
            "Open Claude Code and send one prompt to initialize usage."
        case .incompleteWindows:
            "Claude supplied partial usage; waiting for both windows."
        case .unsupportedSchema:
            "Climeter usage exporter needs an update."
        case .invalidFile, nil:
            "Claude usage file is invalid."
        }
    }

    static func normalizedError(_ error: Error) -> ClaudeStatusLineUsageError {
        if let error = error as? ClaudeStatusLineUsageError {
            return error
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [
               CocoaError.Code.fileNoSuchFile.rawValue,
               CocoaError.Code.fileReadNoSuchFile.rawValue
           ].contains(error.code) {
            return .missingFile
        }
        return .invalidFile
    }

    func updateStaleness(now: Date) {
        isStale = lastSuccessAt.map {
            now.timeIntervalSince($0) > Self.staleThreshold
        } ?? false
    }
}
