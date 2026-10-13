import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Battery vs. mains, for `ScanContext.isOnBattery` (heavy scanners such as
/// Similar Images throttle themselves on battery).
public enum PowerState {
    /// `true` when the Mac is currently drawing from its battery. Desktops and
    /// any failure to read the power-source snapshot report `false`.
    public static var isOnBattery: Bool {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        // The returned CFString is owned by the snapshot: do not release it.
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (providing as String) == kIOPSBatteryPowerValue
        #else
        return ProcessInfo.processInfo.isLowPowerModeEnabled
        #endif
    }
}
