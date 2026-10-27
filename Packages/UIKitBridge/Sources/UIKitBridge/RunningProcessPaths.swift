import Darwin
import Foundation
import ProtectionModule

/// `RunningProcessPathsProvider` backed by libproc: `proc_listallpids` for the
/// pid table, `proc_pidpath` for each executable. Kernel tasks and processes
/// that exit between the two calls simply have no path and are skipped.
/// The result is deduplicated (many pids share `/usr/libexec/xpcproxy`-style
/// binaries) and sorted so the caller's quick-scan roots are stable.
///
/// Both calls are syscalls over every pid on the system, so the work runs on a
/// detached utility task rather than the caller's actor.
public struct RunningProcessPaths: RunningProcessPathsProvider {
    public init() {}

    public func executablePaths() async -> [URL] {
        await Task.detached(priority: .utility) {
            RunningProcessPaths.collect()
        }.value
    }

    static func collect() -> [URL] {
        var seen = Set<String>()
        for pid in LibProc.listPIDs() {
            if let path = LibProc.executablePath(pid), !path.isEmpty {
                seen.insert(path)
            }
        }
        return seen.sorted().map { URL(fileURLWithPath: $0) }
    }
}

/// Thin libproc wrappers shared by the Protection bridges. `DarwinProcessSampler`
/// carries its own private copies with identical semantics.
enum LibProc {
    static func listPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Headroom for processes spawned between the sizing and the listing call.
        var buffer = [pid_t](repeating: 0, count: Int(needed) + 64)
        let byteCount = Int32(buffer.count * MemoryLayout<pid_t>.stride)
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listallpids(raw.baseAddress, byteCount)
        }
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written))).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}
