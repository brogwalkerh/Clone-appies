import Foundation

/// One snapshot of a running process. Sampling is platform-specific
/// (UIKitBridge on macOS); ranking lives here so it is testable on Linux.
public struct ProcessSample: Sendable, Hashable, Codable, Identifiable {
    public let id: Int32            // pid
    public let name: String
    public let bundleIdentifier: String?
    public let cpuPercent: Double   // 0...100*cores
    public let residentBytes: Int64
    public let energyImpact: Double?   // nil when unavailable
    public let isResponsive: Bool?     // nil when unknown
    public let isSystem: Bool

    public init(id: Int32, name: String, bundleIdentifier: String? = nil, cpuPercent: Double,
                residentBytes: Int64, energyImpact: Double? = nil, isResponsive: Bool? = nil,
                isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.energyImpact = energyImpact
        self.isResponsive = isResponsive
        self.isSystem = isSystem
    }
}

public protocol ProcessSampler: Sendable {
    func sample() async throws -> [ProcessSample]
}

/// Picks the processes worth showing in Heavy Consumers.
public struct HeavyConsumersRanker: Sendable {
    /// Resident memory that counts as one "unit" of the score (4 GB).
    public static let memoryScoreUnit: Double = 4_000_000_000
    /// System processes must exceed the thresholds by this factor to be listed.
    public static let systemThresholdFactor: Double = 2

    public let cpuThreshold: Double
    public let memoryThreshold: Int64

    public init(cpuThreshold: Double = 20, memoryThreshold: Int64 = 1_000_000_000) {
        self.cpuThreshold = cpuThreshold
        self.memoryThreshold = memoryThreshold
    }

    /// Heavy first. A process qualifies when its CPU or resident memory reaches
    /// the threshold; system processes only when they reach twice it. Ordered by
    /// `score` descending, ties by pid ascending.
    public func rank(_ samples: [ProcessSample]) -> [ProcessSample] {
        samples
            .filter(isHeavy)
            .sorted { lhs, rhs in
                let left = Self.score(lhs)
                let right = Self.score(rhs)
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
    }

    /// Processes known to be unresponsive, by name then pid.
    public func hung(_ samples: [ProcessSample]) -> [ProcessSample] {
        samples
            .filter { $0.isResponsive == false }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }
    }

    /// `cpuPercent / 100 + residentBytes / 4 GB`.
    public static func score(_ sample: ProcessSample) -> Double {
        sample.cpuPercent / 100 + Double(sample.residentBytes) / memoryScoreUnit
    }

    func isHeavy(_ sample: ProcessSample) -> Bool {
        let factor = sample.isSystem ? Self.systemThresholdFactor : 1
        return sample.cpuPercent >= cpuThreshold * factor
            || Double(sample.residentBytes) >= Double(memoryThreshold) * factor
    }
}
