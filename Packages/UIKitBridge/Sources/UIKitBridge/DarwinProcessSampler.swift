import AppKit
import ApplicationServices
import Darwin
import Foundation
import PerformanceModule

/// `ProcessSampler` backed by libproc, AppKit and the Accessibility API.
///
/// - pids: `proc_listallpids`
/// - CPU: two `proc_pid_rusage(RUSAGE_INFO_V4)` snapshots one second apart;
///   `ri_user_time + ri_system_time` are Mach absolute units, converted with
///   `mach_timebase_info` and divided by the wall-clock window.
/// - resident memory: `ri_resident_size` from the second snapshot
/// - name / bundle id: `NSRunningApplication(processIdentifier:)`, falling back
///   to `proc_name` and the last component of `proc_pidpath`
/// - `isSystem`: uid 0 (`PROC_PIDTBSDINFO`) or an executable under `/System`
///   or `/usr/libexec`
/// - `isResponsive`: for processes with a bundle id, `AXUIElementCopyAttributeValue`
///   with a 1 s messaging timeout; a timeout means hung
/// - `energyImpact`: always nil (no public API)
///
/// `sample()` always runs on a detached utility task so the one-second window
/// never blocks the caller's actor.
public struct DarwinProcessSampler: ProcessSampler {
    /// Wall-clock window between the two rusage snapshots.
    public static let sampleWindow: Duration = .seconds(1)

    public init() {}

    public func sample() async throws -> [ProcessSample] {
        try await Task.detached(priority: .utility) {
            try await DarwinProcessSampler.collect()
        }.value
    }

    // MARK: Collection

    private struct Usage: Sendable {
        var cpuTimeMach: UInt64
        var residentBytes: UInt64
    }

    private static func collect() async throws -> [ProcessSample] {
        let pids = listPIDs()
        let clock = ContinuousClock()
        let start = clock.now
        var first: [pid_t: Usage] = [:]
        first.reserveCapacity(pids.count)
        for pid in pids {
            if let usage = readUsage(pid) { first[pid] = usage }
        }

        try await Task.sleep(for: sampleWindow)
        try Task.checkCancellation()

        let elapsedNanos = (clock.now - start).totalSeconds * 1_000_000_000
        let timebase = machTimebase()
        let accessibilityTrusted = AXIsProcessTrusted()

        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        for pid in pids {
            guard let before = first[pid], let after = readUsage(pid) else { continue }   // exited mid-window
            let deltaMach = after.cpuTimeMach >= before.cpuTimeMach ? after.cpuTimeMach - before.cpuTimeMach : 0
            let deltaNanos = Double(deltaMach) * timebase
            let cpuPercent = elapsedNanos > 0 ? (deltaNanos / elapsedNanos) * 100 : 0

            let path = executablePath(pid)
            // TODO(macOS27): NSRunningApplication is documented thread-safe and is not
            // @MainActor in the 26 SDK. If the 27 SDK isolates it, hop to MainActor
            // once for the whole batch (NSWorkspace.shared.runningApplications).
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleIdentifier = app?.bundleIdentifier
            let name = app?.localizedName
                ?? processName(pid)
                ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "pid \(pid)"
            let uid = ownerUID(pid)
            let system = isSystem(uid: uid, executablePath: path)

            var responsive: Bool? = nil
            if accessibilityTrusted, bundleIdentifier != nil, let app, app.activationPolicy != .prohibited {
                responsive = probeResponsiveness(pid: pid)
            }

            samples.append(ProcessSample(id: pid,
                                         name: name,
                                         bundleIdentifier: bundleIdentifier,
                                         cpuPercent: cpuPercent,
                                         residentBytes: Int64(clamping: after.residentBytes),
                                         energyImpact: nil,
                                         isResponsive: responsive,
                                         isSystem: system))
        }
        return samples
    }

    // MARK: Classification (pure, tested)

    /// uid 0 or an executable under /System or /usr/libexec counts as system.
    static func isSystem(uid: uid_t?, executablePath: String?) -> Bool {
        if uid == 0 { return true }
        guard let executablePath else { return false }
        return executablePath.hasPrefix("/System/") || executablePath.hasPrefix("/usr/libexec/")
    }

    /// Maps an Accessibility probe result to the contract's tri-state.
    /// `.cannotComplete` is what a messaging timeout returns, so it means hung.
    /// Anything else that is not success (API disabled, no Accessibility
    /// permission, non-Cocoa process) is "unknown".
    static func responsiveness(from error: AXError) -> Bool? {
        switch error {
        case .success: return true
        case .cannotComplete: return false
        default: return nil
        }
    }

    // MARK: libproc helpers (nonisolated, synchronous)

    private static func listPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        var buffer = [pid_t](repeating: 0, count: Int(needed) + 64)
        let byteCount = Int32(buffer.count * MemoryLayout<pid_t>.stride)
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listallpids(raw.baseAddress, byteCount)
        }
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written))).filter { $0 > 0 }
    }

    private static func readUsage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return Usage(cpuTimeMach: info.ri_user_time &+ info.ri_system_time,
                     residentBytes: info.ri_resident_size)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        let name = string(fromCString: buffer)
        return name.isEmpty ? nil : name
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        let path = string(fromCString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Decodes a NUL-terminated buffer without going through the deprecated
    /// `String(cString: [CChar])` overload.
    private static func string(fromCString buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func ownerUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard written == size else { return nil }
        return info.pbi_uid
    }

    /// Nanoseconds per Mach absolute time unit.
    private static func machTimebase() -> Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }

    // MARK: Accessibility probe

    /// Asks the app's accessibility server for its window list with a 1 s
    /// timeout. Hung apps never answer, which surfaces as `.cannotComplete`.
    private static func probeResponsiveness(pid: pid_t) -> Bool? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        return responsiveness(from: error)
    }
}
