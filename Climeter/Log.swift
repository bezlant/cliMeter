import Foundation
import os
import Security

// MARK: - File Logger

final class FileLog: @unchecked Sendable {
    static let shared = FileLog()

    private let queue = DispatchQueue(label: "com.bezlant.climeter.filelog")
    private var fileHandle: FileHandle?
    private let filePath: String
    private let maxFileSize: UInt64 = 2 * 1024 * 1024 // 2 MB
    private let dateFormatter: DateFormatter

    private init() {
        let logsDir = Self.logsDirectory()
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let path = logsDir.appendingPathComponent("climeter.log").path
        self.filePath = path

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        self.fileHandle = FileHandle(forWritingAtPath: path)
        self.fileHandle?.seekToEndOfFile()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = df
    }

    static func logsDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if environment["XCTestConfigurationFilePath"] != nil {
            return temporaryDirectory
                .appendingPathComponent("ClimeterTests")
                .appendingPathComponent("Logs")
        }
        return homeDirectory.appendingPathComponent("Library/Logs/Climeter")
    }

    func write(level: String, category: String, message: String) {
        queue.async { [self] in
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(category)] [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            rotateIfNeeded()
            fileHandle?.write(data)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else { return }

        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()

        let rotated = filePath + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: filePath, toPath: rotated)

        FileManager.default.createFile(atPath: filePath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: filePath)
    }
}

// MARK: - Dual Logger

struct DualLogger {
    private let osLogger: Logger
    private let category: String

    init(category: String) {
        self.osLogger = Logger(subsystem: "com.bezlant.climeter", category: category)
        self.category = category
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
        FileLog.shared.write(level: "DEBUG", category: category, message: message)
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        FileLog.shared.write(level: "INFO", category: category, message: message)
    }

    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        FileLog.shared.write(level: "WARN", category: category, message: message)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        FileLog.shared.write(level: "ERROR", category: category, message: message)
    }
}

// MARK: - Log Namespace

enum Log {
    static let keychain = DualLogger(category: "keychain")
    static let cliSync = DualLogger(category: "cli-sync")
    static let api = DualLogger(category: "api")
    static let coordinator = DualLogger(category: "coordinator")
    static let profiles = DualLogger(category: "profiles")
    static let fileStore = DualLogger(category: "file-store")

    /// Human-readable description for common keychain OSStatus codes.
    static func keychainStatus(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:                return "success(0)"
        case errSecItemNotFound:           return "itemNotFound(-25300)"
        case errSecAuthFailed:             return "authFailed(-25293)"
        case errSecInteractionNotAllowed:  return "interactionNotAllowed(-25308)"
        case errSecDuplicateItem:          return "duplicateItem(-25299)"
        case errSecUserCanceled:           return "userCanceled(-128)"
        case errSecMissingEntitlement:     return "missingEntitlement(-34018)"
        case -25320:                       return "inDarkWake(-25320)"
        case -60008:                       return "authorizationInternal(-60008)"
        default:                           return "OSStatus(\(status))"
        }
    }

    static func isTransientKeychainError(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed  // -25308
            || status == -25320               // errSecInDarkWake
            || status == -60008               // errAuthorizationInternal
    }
}
