import AppKit
import Foundation

protocol PowerStateMonitoring: AnyObject {
    var isScreenLocked: Bool { get }
    var onSleep: (() -> Void)? { get set }
    var onWake: (() -> Void)? { get set }
    var onScreenUnlocked: (() -> Void)? { get set }

    func startMonitoring()
    func stopMonitoring()
}

final class PowerStateMonitor: ObservableObject, PowerStateMonitoring {
    @Published private(set) var isSystemAwake = true
    @Published private(set) var isScreenLocked = false

    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onScreenUnlocked: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func startMonitoring() {
        guard observers.isEmpty else { return }
        let wsnc = NSWorkspace.shared.notificationCenter

        observers.append(wsnc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.profiles.info("system going to sleep \u{2014} pausing coordinators")
            self?.isSystemAwake = false
            self?.onSleep?()
        })

        observers.append(wsnc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.profiles.info("system woke up \u{2014} waiting for screen unlock")
            self?.isSystemAwake = true
            self?.onWake?()
        })

        let dnc = DistributedNotificationCenter.default()

        observers.append(dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.profiles.info("screen locked")
            self?.isScreenLocked = true
        })

        observers.append(dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.profiles.info("screen unlocked \u{2014} retrying keychain + resuming polling")
            self?.isScreenLocked = false
            self?.onScreenUnlocked?()
        })
    }

    func stopMonitoring() {
        let wsnc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for observer in observers {
            wsnc.removeObserver(observer)
            dnc.removeObserver(observer)
        }
        observers.removeAll()
    }
}
