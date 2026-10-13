import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Model

/// Coarse memory pressure derived from `vm_statistics64` (see
/// `MemoryPressure.derived`). `DISPATCH_MEMORYPRESSURE` is event-driven and
/// cannot be polled, so the sampler infers the level from free + inactive pages.
public enum MemoryPressure: String, Sendable, Hashable, Codable, CaseIterable {
    case normal
    case warn
    case critical

    /// Thresholds: critical below 5 % available, warn below 15 %.
    public static let criticalFraction = 0.05
    public static let warnFraction = 0.15

    /// Pure threshold math, factored out so it can be unit-tested without a
    /// Mach host port. `availableBytes` is free + inactive memory.
    public static func derived(availableBytes: Int64, totalBytes: Int64) -> MemoryPressure {
        guard totalBytes > 0 else { return .normal }
        let fraction = Double(max(availableBytes, 0)) / Double(totalBytes)
        if fraction < criticalFraction { return .critical }
        if fraction < warnFraction { return .warn }
        return .normal
    }
}

/// One snapshot of the machine, per docs/CONTRACTS.md "M3 — UIKitBridge additions".
public struct SystemStats: Sendable, Hashable {
    /// 0...100 across all cores (user + system + nice over total ticks).
    public let cpuPercent: Double
    /// active + wired + compressor pages × page size.
    public let memoryUsedBytes: Int64
    public let memoryTotalBytes: Int64
    public let memoryPressure: MemoryPressure
    /// Bytes on the boot volume not reported as available (includes purgeable).
    public let diskUsedBytes: Int64
    public let diskTotalBytes: Int64
    /// Space macOS could reclaim on demand (important-usage availability minus plain availability).
    public let purgeableBytes: Int64
    /// nil on desktops.
    public let batteryPercent: Double?
    public let batteryCycleCount: Int?
    /// max capacity / design capacity, 0...1. nil on desktops.
    public let batteryHealth: Double?
    public let isCharging: Bool?
    public let networkInBytesPerSec: Double
    public let networkOutBytesPerSec: Double

    public init(cpuPercent: Double,
                memoryUsedBytes: Int64,
                memoryTotalBytes: Int64,
                memoryPressure: MemoryPressure,
                diskUsedBytes: Int64,
                diskTotalBytes: Int64,
                purgeableBytes: Int64,
                batteryPercent: Double?,
                batteryCycleCount: Int?,
                batteryHealth: Double?,
                isCharging: Bool?,
                networkInBytesPerSec: Double,
                networkOutBytesPerSec: Double) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.purgeableBytes = purgeableBytes
        self.batteryPercent = batteryPercent
        self.batteryCycleCount = batteryCycleCount
        self.batteryHealth = batteryHealth
        self.isCharging = isCharging
        self.networkInBytesPerSec = networkInBytesPerSec
        self.networkOutBytesPerSec = networkOutBytesPerSec
    }

    /// `true` when the machine reports an internal battery.
    public var hasBattery: Bool { batteryPercent != nil }
}

// MARK: - Sampler

/// Polls host statistics every `interval` and yields a `SystemStats` per tick.
/// CPU and network are deltas against the previous tick, so the first value
/// arrives one interval after `stream()` is first iterated. Cancelling the
/// consuming task (or dropping the stream) stops the sampler.
public actor SystemStatsSampler {
    private let interval: Duration

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public func stream() -> AsyncStream<SystemStats> {
        let (stream, continuation) = AsyncStream<SystemStats>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let interval = self.interval
        let task = Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            var previousCPU = HostStatistics.cpuTicks()
            var previousNetwork = HostStatistics.networkCounters()
            var previousTime = clock.now
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                let now = clock.now
                let elapsed = max((now - previousTime).totalSeconds, 0.001)
                let cpu = HostStatistics.cpuTicks()
                let network = HostStatistics.networkCounters()
                let stats = HostStatistics.snapshot(cpuPercent: HostStatistics.cpuPercent(from: previousCPU, to: cpu),
                                                    network: HostStatistics.networkRate(from: previousNetwork, to: network, seconds: elapsed))
                previousCPU = cpu
                previousNetwork = network
                previousTime = now
                if Task.isCancelled { break }
                continuation.yield(stats)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - Darwin plumbing

/// Small nonisolated wrappers over Mach, IOKit and BSD calls. Every function
/// is synchronous, allocation-light and safe to call from any thread.
enum HostStatistics {
    // MARK: CPU

    struct CPUTicks: Sendable, Hashable {
        var busy: UInt64 = 0
        var total: UInt64 = 0
    }

    /// Sums `PROCESSOR_CPU_LOAD_INFO` over every core.
    static func cpuTicks() -> CPUTicks {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return CPUTicks() }
        defer {
            // TODO(macOS27): `mach_task_self_` is an imported C global; SE-0412 treats
            // those as nonisolated(unsafe). If the 27 SDK flags it, switch to a
            // cached port read once at startup.
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }
        let states = Int(CPU_STATE_MAX)
        var ticks = CPUTicks()
        for core in 0..<Int(cpuCount) {
            let base = core * states
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            ticks.busy += user + system + nice
            ticks.total += user + system + idle + nice
        }
        return ticks
    }

    static func cpuPercent(from previous: CPUTicks, to current: CPUTicks) -> Double {
        guard current.total > previous.total else { return 0 }
        let total = Double(current.total - previous.total)
        let busy = Double(current.busy >= previous.busy ? current.busy - previous.busy : 0)
        return min(100, max(0, busy / total * 100))
    }

    // MARK: Memory

    struct MemorySnapshot: Sendable {
        var usedBytes: Int64
        var totalBytes: Int64
        var availableBytes: Int64
    }

    static func memory() -> MemorySnapshot {
        let total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        var pageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize) != KERN_SUCCESS || pageSize == 0 {
            pageSize = vm_size_t(sysconf(_SC_PAGESIZE))
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(usedBytes: 0, totalBytes: total, availableBytes: total)
        }
        let page = Int64(pageSize)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        let available = (Int64(stats.free_count) + Int64(stats.inactive_count)) * page
        return MemorySnapshot(usedBytes: min(used, total), totalBytes: total, availableBytes: available)
    }

    // MARK: Disk

    struct DiskSnapshot: Sendable {
        var usedBytes: Int64
        var totalBytes: Int64
        var purgeableBytes: Int64
    }

    static func bootVolume() -> DiskSnapshot {
        let root = URL(fileURLWithPath: "/")
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity
        else {
            return DiskSnapshot(usedBytes: 0, totalBytes: 0, purgeableBytes: 0)
        }
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        let purgeable = max(important - available, 0)
        return DiskSnapshot(usedBytes: max(Int64(total) - available, 0),
                            totalBytes: Int64(total),
                            purgeableBytes: purgeable)
    }

    // MARK: Battery

    struct BatterySnapshot: Sendable {
        var percent: Double?
        var isCharging: Bool?
        var cycleCount: Int?
        var health: Double?
    }

    static func battery() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        if let status = powerSourceStatus() {
            snapshot.percent = status.percent
            snapshot.isCharging = status.isCharging
            let registry = smartBatteryProperties()
            snapshot.cycleCount = registry.cycleCount
            snapshot.health = registry.health
        }
        return snapshot
    }

    /// Charge level and charging flag from the power-sources snapshot; nil when
    /// there is no internal battery (desktops).
    private static func powerSourceStatus() -> (percent: Double, isCharging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let type = description[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType {
                continue
            }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Double(current) / Double(maximum) * 100 : Double(current)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (min(100, max(0, percent)), charging)
        }
        return nil
    }

    /// Cycle count and max/design capacity from the AppleSmartBattery registry
    /// entry. Apple Silicon reports `MaxCapacity` as a percentage and the real
    /// mAh in `AppleRawMaxCapacity`, so prefer the raw key.
    private static func smartBatteryProperties() -> (cycleCount: Int?, health: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return (nil, nil) }
        let cycles = properties["CycleCount"] as? Int
        let maximum = (properties["AppleRawMaxCapacity"] as? Int)
            ?? (properties["NominalChargeCapacity"] as? Int)
            ?? (properties["MaxCapacity"] as? Int)
        let design = properties["DesignCapacity"] as? Int
        var health: Double? = nil
        if let maximum, let design, design > 0, maximum > 0 {
            health = min(1, max(0, Double(maximum) / Double(design)))
        }
        return (cycles, health)
    }

    // MARK: Network

    struct NetworkCounters: Sendable {
        /// Per-interface (in, out) byte counters. `if_data` counters are 32-bit
        /// and wrap, so deltas are computed per interface.
        var interfaces: [String: (UInt64, UInt64)] = [:]
    }

    static func networkCounters() -> NetworkCounters {
        var counters = NetworkCounters()
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return counters }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK else { continue }
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
            guard let raw = entry.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: entry.pointee.ifa_name)
            counters.interfaces[name] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
        }
        return counters
    }

    static func networkRate(from previous: NetworkCounters, to current: NetworkCounters, seconds: Double) -> (inPerSec: Double, outPerSec: Double) {
        guard seconds > 0 else { return (0, 0) }
        var inDelta: UInt64 = 0
        var outDelta: UInt64 = 0
        for (name, now) in current.interfaces {
            guard let before = previous.interfaces[name] else { continue }
            inDelta += wrappedDelta(from: before.0, to: now.0)
            outDelta += wrappedDelta(from: before.1, to: now.1)
        }
        return (Double(inDelta) / seconds, Double(outDelta) / seconds)
    }

    /// Delta for a 32-bit counter that may have wrapped once.
    static func wrappedDelta(from before: UInt64, to now: UInt64) -> UInt64 {
        if now >= before { return now - before }
        return (UInt64(UInt32.max) + 1 - before) + now
    }

    // MARK: Assembly

    static func snapshot(cpuPercent: Double, network: (inPerSec: Double, outPerSec: Double)) -> SystemStats {
        let mem = memory()
        let disk = bootVolume()
        let power = battery()
        return SystemStats(cpuPercent: cpuPercent,
                           memoryUsedBytes: mem.usedBytes,
                           memoryTotalBytes: mem.totalBytes,
                           memoryPressure: MemoryPressure.derived(availableBytes: mem.availableBytes,
                                                                  totalBytes: mem.totalBytes),
                           diskUsedBytes: disk.usedBytes,
                           diskTotalBytes: disk.totalBytes,
                           purgeableBytes: disk.purgeableBytes,
                           batteryPercent: power.percent,
                           batteryCycleCount: power.cycleCount,
                           batteryHealth: power.health,
                           isCharging: power.isCharging,
                           networkInBytesPerSec: network.inPerSec,
                           networkOutBytesPerSec: network.outPerSec)
    }
}
