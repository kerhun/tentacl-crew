import Foundation
import AppKit
import IOKit.ps

/// What the guard needs to know about the power source.
struct PowerSnapshot: Equatable {
    /// False on a Mac without an internal battery (no lid to close).
    var hasBattery: Bool
    var onBattery: Bool
    var percent: Int?
}

/// Power-source changes and sleep/wake, behind a small interface so tests drive them by hand.
@MainActor
protocol PowerEnvironment: AnyObject {
    var snapshot: PowerSnapshot { get }
    func start(onChange: @escaping @MainActor () -> Void, willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void)
}

/// IOKit's power-source notification (plug, unplug, charge level) and NSWorkspace's will-sleep / did-wake.
@MainActor
final class SystemPowerEnvironment: PowerEnvironment {
    private var onChange: (@MainActor () -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    /// The IOKit callback holds `self` unretained, so its source must go with it (a power change after this would reach freed memory).
    deinit {
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    var snapshot: PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerSnapshot(hasBattery: false, onBattery: false, percent: nil)
        }
        var hasBattery = false
        var percent: Int?
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            if let now = d[kIOPSCurrentCapacityKey] as? Int, let full = d[kIOPSMaxCapacityKey] as? Int, full > 0 { percent = now * 100 / full }
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return PowerSnapshot(hasBattery: hasBattery, onBattery: hasBattery && providing == kIOPSBatteryPowerValue, percent: percent)
    }

    func start(onChange: @escaping @MainActor () -> Void, willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        if runLoopSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let me = Unmanaged<SystemPowerEnvironment>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { me.onChange?() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                runLoopSource = source
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { willSleep() } },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { didWake() } },
        ]
    }
}
