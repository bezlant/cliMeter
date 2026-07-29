import SwiftUI

@main
struct ClimeterApp: App {
    @StateObject private var profileManager = ProfileManager()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var menuBarTime = Date.now
    private let menuBarTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bezlant.climeter"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current }
        if let existing = others.first {
            NSLog("Another Climeter already running (PID %d) — exiting", existing.processIdentifier)
            existing.activate()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(profileManager: profileManager, updateChecker: updateChecker)
        } label: {
            Group {
                if let usageData = profileManager.cliActiveUsageData {
                    let utilization = usageData.fiveHour.utilization
                    let isPeak = profileManager.peakHoursEnabled && PeakHoursService.isPeakNow()
                    let activeProfile = profileManager.cliActiveProfile
                    let activeProfileID = activeProfile?.id
                    let isStale = ClaudeStalePresentation.isWaiting(
                        usageSource: profileManager.claudeUsageSource,
                        credentialSource: activeProfile?.credentialSource ?? .cliSynced,
                        isStale: activeProfileID.map { profileManager.allStale[$0] == true } ?? false,
                        lastSuccessAt: activeProfileID.flatMap { profileManager.allLastSuccess[$0] },
                        currentTime: menuBarTime
                    )
                    Image(nsImage: MenuBarIcon.progressBar(utilization: utilization, isPeak: isPeak, isStale: isStale))
                } else {
                    Text("—")
                }
            }
            .onReceive(menuBarTimer) { time in
                menuBarTime = time
            }
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(profileManager: profileManager)
        }
        .windowResizability(.contentSize)
    }
}
