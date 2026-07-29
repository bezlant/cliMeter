import SwiftUI

struct PopoverView: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var updateChecker: UpdateChecker
    @State private var currentTime = Date.now
    @Environment(\.openWindow) private var openWindow

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var shouldShowClaude: Bool {
        profileManager.claudeEnabled
    }

    private var shouldShowCodex: Bool {
        profileManager.codexEnabled
            || profileManager.codexUsageData != nil
            || profileManager.codexErrorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            if (!shouldShowClaude || profileManager.authenticatedProfiles.isEmpty) && !shouldShowCodex {
                VStack(spacing: 8) {
                    if !shouldShowClaude && !shouldShowCodex {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Usage display is hidden.\nEnable providers in Settings.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Run /login in Claude Code\nto connect an account")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if profileManager.peakHoursEnabled {
                            PeakHoursBanner(currentTime: currentTime)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }

                        if shouldShowClaude {
                            if profileManager.authenticatedProfiles.count > 1 {
                                HStack(spacing: 4) {
                                    Text("Claude")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                    ProviderBadge(text: "Anthropic", color: .blue)
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 4)
                            }

                            ForEach(Array(profileManager.authenticatedProfiles.enumerated()), id: \.element.id) { index, profile in
                                ProfileCard(
                                    profile: profile,
                                    usageSource: profileManager.claudeUsageSource,
                                    usageData: profileManager.allUsageData[profile.id],
                                    errorMessage: profileManager.allErrors[profile.id],
                                    lastSuccessAt: profileManager.allLastSuccess[profile.id],
                                    isStale: profileManager.allStale[profile.id] == true,
                                    isCLIActive: profileManager.cliActiveProfileID == profile.id,
                                    showProfileName: profileManager.authenticatedProfiles.count > 1,
                                    currentTime: currentTime
                                )
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            }
                        }

                        if shouldShowCodex {
                            ProviderUsageCard(
                                title: "Codex",
                                badgeText: "OpenAI",
                                usageData: profileManager.codexUsageData,
                                errorMessage: profileManager.codexErrorMessage,
                                lastSuccessAt: profileManager.codexLastSuccessAt,
                                currentTime: currentTime
                            )
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Update banner
            if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                Divider().opacity(0.5)

                HStack(spacing: 6) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 5, height: 5)
                    if let urlString = updateChecker.releaseURL,
                       let url = URL(string: urlString) {
                        Link("v\(version) available", destination: url)
                            .font(.system(size: 11))
                            .foregroundColor(.blue.opacity(0.9))
                    } else {
                        Text("v\(version) available")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { updateChecker.dismissUpdate() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            // Footer
            HStack(spacing: 6) {
                HeaderButton(icon: "gear", help: "Settings") {
                    openWindow(id: "settings")
                }

                Spacer()

                if (shouldShowClaude && profileManager.hasAnyAuthenticated) || shouldShowCodex {
                    HeaderButton(icon: "arrow.clockwise", help: "Refresh") {
                        profileManager.refresh()
                    }
                }
                HeaderButton(icon: "power", help: "Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .background(.regularMaterial)
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

// MARK: - Header Button

struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Profile Card

enum ClaudeStalePresentation {
    /// Claude Code may keep running with read-only credentials while API usage
    /// refreshes lag; after this, make the stale state explicit in the UI.
    static let staleThreshold: TimeInterval = 10 * 60

    static func isWaiting(
        usageSource: ClaudeUsageSource,
        credentialSource: CredentialSource,
        isStale: Bool,
        lastSuccessAt: Date?,
        currentTime: Date
    ) -> Bool {
        guard usageSource == .statusLineFile || credentialSource == .cliSynced else {
            return false
        }
        if isStale { return true }
        guard let lastSuccessAt else { return false }
        return currentTime.timeIntervalSince(lastSuccessAt) > staleThreshold
    }

    static func waitingMessage(
        usageSource: ClaudeUsageSource,
        credentialSource: CredentialSource,
        isStale: Bool,
        lastSuccessAt: Date?,
        currentTime: Date,
        errorMessage: String? = nil
    ) -> String? {
        guard isWaiting(
            usageSource: usageSource,
            credentialSource: credentialSource,
            isStale: isStale,
            lastSuccessAt: lastSuccessAt,
            currentTime: currentTime
        ) else { return nil }
        guard let lastSuccessAt else { return "Waiting for Claude Code" }
        let age = currentTime.timeIntervalSince(lastSuccessAt)
        if errorMessage == "Rate limited — retrying soon" {
            return "Updated \(formatStaleAge(age)) — rate limited, retrying"
        }
        return "Updated \(formatStaleAge(age)) — waiting for Claude Code"
    }

    static func formatStaleAge(_ age: TimeInterval) -> String {
        let minutes = Int(age) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remMin = minutes % 60
        return remMin > 0 ? "\(hours)h \(remMin)m ago" : "\(hours)h ago"
    }
}

struct ClaudeProfileCardPresentation {
    enum Row: Equatable {
        case usage
        case error(String)
        case loading
        case waiting(String)
    }

    let staleAge: TimeInterval?
    let rows: [Row]

    static func make(
        usageSource: ClaudeUsageSource,
        credentialSource: CredentialSource,
        hasUsageData: Bool,
        errorMessage: String?,
        lastSuccessAt: Date?,
        isStale: Bool,
        currentTime: Date
    ) -> ClaudeProfileCardPresentation {
        let waitingMessage = ClaudeStalePresentation.waitingMessage(
            usageSource: usageSource,
            credentialSource: credentialSource,
            isStale: isStale,
            lastSuccessAt: lastSuccessAt,
            currentTime: currentTime,
            errorMessage: errorMessage
        )
        let visibleError = errorMessage.flatMap { message in
            hasUsageData && usageSource != .statusLineFile ? nil : message
        }

        if usageSource == .statusLineFile,
           let visibleError,
           isFileValidationError(visibleError) {
            return ClaudeProfileCardPresentation(
                staleAge: nil,
                rows: hasUsageData ? [.usage, .error(visibleError)] : [.error(visibleError)]
            )
        }

        var rows: [Row] = []
        if hasUsageData {
            rows.append(.usage)
        } else if visibleError == nil, waitingMessage == nil {
            rows.append(.loading)
        }
        if let visibleError {
            rows.append(.error(visibleError))
        }
        if let waitingMessage {
            rows.append(.waiting(waitingMessage))
        }

        let staleAge = hasUsageData
            ? lastSuccessAt
                .map { currentTime.timeIntervalSince($0) }
                .flatMap { $0 > ClaudeStalePresentation.staleThreshold ? $0 : nil }
            : nil
        return ClaudeProfileCardPresentation(staleAge: staleAge, rows: rows)
    }

    private static func isFileValidationError(_ message: String) -> Bool {
        message == "Climeter usage exporter needs an update."
            || message == "Claude usage file is invalid."
    }
}

struct ProfileCard: View {
    let profile: Profile
    let usageSource: ClaudeUsageSource
    let usageData: UsageData?
    let errorMessage: String?
    let lastSuccessAt: Date?
    let isStale: Bool
    let isCLIActive: Bool
    let showProfileName: Bool
    let currentTime: Date

    private var presentation: ClaudeProfileCardPresentation {
        ClaudeProfileCardPresentation.make(
            usageSource: usageSource,
            credentialSource: profile.credentialSource,
            hasUsageData: usageData != nil,
            errorMessage: errorMessage,
            lastSuccessAt: lastSuccessAt,
            isStale: isStale,
            currentTime: currentTime
        )
    }

    static func formatStaleAgeForProvider(_ age: TimeInterval) -> String {
        ClaudeStalePresentation.formatStaleAge(age)
    }

    private func staleLabel(_ age: TimeInterval) -> some View {
        Text("stale \(ClaudeStalePresentation.formatStaleAge(age))")
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundColor(.secondary.opacity(0.7))
    }

    @ViewBuilder
    private func presentationRow(_ row: ClaudeProfileCardPresentation.Row) -> some View {
        switch row {
        case .usage:
            if let usageData {
                UsageRow(
                    label: "Session",
                    window: usageData.fiveHour,
                    currentTime: currentTime
                )
                UsageRow(
                    label: "Week",
                    window: usageData.sevenDay,
                    currentTime: currentTime
                )
            }
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        case .waiting(let message):
            Text(message)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("claude-stale-status")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showProfileName {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text("Claude")
                        .font(.system(size: 12, weight: .semibold))
                    ProviderBadge(text: "Anthropic", color: .blue)
                }

                if isCLIActive && showProfileName {
                    CLIBadge()
                }

                Spacer()

                if let age = presentation.staleAge {
                    staleLabel(age)
                }
            }

            ForEach(presentation.rows.indices, id: \.self) { index in
                presentationRow(presentation.rows[index])
            }
        }
    }
}

// MARK: - Provider Usage Card

struct ProviderUsageCard: View {
    let title: String
    let badgeText: String?
    let usageData: UsageData?
    let errorMessage: String?
    let lastSuccessAt: Date?
    let currentTime: Date

    private static let staleThreshold: TimeInterval = UsageRefreshCoordinator.baseInterval * 3

    private var staleAge: TimeInterval? {
        guard usageData != nil, let lastSuccessAt else { return nil }
        let age = currentTime.timeIntervalSince(lastSuccessAt)
        return age > Self.staleThreshold ? age : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let badgeText {
                    ProviderBadge(text: badgeText, color: .blue)
                }
                Spacer()
                if let staleAge {
                    Text("stale \(ProfileCard.formatStaleAgeForProvider(staleAge))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if let usageData {
                UsageRow(label: "Session", window: usageData.fiveHour, currentTime: currentTime)
                UsageRow(label: "Week", window: usageData.sevenDay, currentTime: currentTime)
            } else if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Peak Hours Banner

struct PeakHoursBanner: View {
    let currentTime: Date

    private var isPeak: Bool {
        PeakHoursService.isPeakNow(at: currentTime)
    }

    private var countdown: String? {
        guard let endTime = PeakHoursService.peakEndTime(at: currentTime) else { return nil }
        let remaining = endTime.timeIntervalSince(currentTime)
        guard remaining > 0 else { return nil }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var nextPeakCountdown: String? {
        guard let nextStart = PeakHoursService.nextPeakStartTime(at: currentTime) else { return nil }
        let remaining = nextStart.timeIntervalSince(currentTime)
        guard remaining > 0 else { return nil }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let days = hours / 24
        let remHours = hours % 24
        if days > 0 { return "\(days)d \(remHours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var body: some View {
        HStack(spacing: 6) {
            if isPeak {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text("Peak hours")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                if let countdown {
                    Text("ends in \(countdown)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.8))
                }
            } else {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text("Off-peak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
                Spacer()
                if let nextPeakCountdown {
                    Text("peak in \(nextPeakCountdown)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPeak ? Color.orange.opacity(0.08) : Color.green.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isPeak ? Color.orange.opacity(0.2) : Color.green.opacity(0.12),
                    lineWidth: 0.5
                )
        )
        .help("Weekdays \(PeakHoursService.localTimeRangeString()) — session limits consumed faster during peak")
    }
}

// MARK: - Provider Badge

struct ProviderBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - CLI Badge

struct CLIBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
            Text("CLI")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.green.opacity(0.12)))
    }
}

// MARK: - Usage Row

struct UsageRow: View {
    let label: String
    let window: UsageWindow
    let currentTime: Date

    private var utilization: Double { window.utilization }

    private var statusColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 60 { return .orange }
        return .green
    }

    private var statusIcon: String {
        if utilization >= 80 { return "exclamationmark.circle.fill" }
        if utilization >= 60 { return "minus.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var countdown: String {
        guard let resetsAt = window.resetsAt else { return "—" }
        let interval = resetsAt.timeIntervalSince(currentTime)
        guard interval > 0 else { return "Resetting..." }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days > 0 {
            return "\(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 9))
                        .foregroundColor(statusColor)
                    Text("\(Int(utilization))%")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                }
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(countdown)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // Custom gradient progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [statusColor, statusColor.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * min(utilization / 100.0, 1.0))
                        .animation(.easeInOut(duration: 0.8), value: utilization)
                }
            }
            .frame(height: 8)
        }
    }
}

#Preview {
    PopoverView(profileManager: ProfileManager(), updateChecker: UpdateChecker())
}
