//
//  MacBattery.swift
//  Tether
//
//  This Mac's battery, for KDE Connect on the phone, which shows a computer's
//  charge in its device list. Read from IOKit's power sources, which also say
//  when something changes, so nothing polls.
//

import Foundation
import IOKit.ps

nonisolated struct MacBatteryStatus: Sendable, Equatable {
    /// 0 to 100.
    var charge: Int
    /// Plugged in. A Mac on power often holds its charge (at 80%, or when
    /// full) rather than charging, but the phone should still show the plug.
    var isCharging: Bool
    var batteryCount: Int

    /// Desktop KDE Connect's rule: low is 15% or less and running on battery.
    var isLow: Bool { charge <= 15 && !isCharging }
}

nonisolated enum MacBattery {
    /// The internal batteries' combined status, or nil on a Mac without one.
    static func status() -> MacBatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var total = 0, count = 0, onPower = false
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            total += current * 100 / max
            count += 1
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                || description[kIOPSIsChargingKey] as? Bool == true {
                onPower = true
            }
        }
        guard count > 0 else { return nil }
        return MacBatteryStatus(charge: total / count, isCharging: onPower, batteryCount: count)
    }

    private static var source: CFRunLoopSource?
    private static var onChange: (() -> Void)?

    /// Calls `handler` on the main run loop whenever a power source changes.
    @MainActor
    static func observe(_ handler: @escaping () -> Void) {
        guard source == nil else { return }
        onChange = handler
        source = IOPSNotificationCreateRunLoopSource({ _ in MacBattery.onChange?() }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
