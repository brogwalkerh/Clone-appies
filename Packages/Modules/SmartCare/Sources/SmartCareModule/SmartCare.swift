import Foundation
import CleanerCore

/// Events from one Smart Care run (PLAN.md §3.1).
public enum SmartCareEvent: Sendable {
    case moduleStarted(ModuleID)
    case moduleProgress(ModuleID, fraction: Double?)
    case finding(ModuleID, Finding)
    case scannerFailed(ModuleID, scannerID: String, message: String)
    case moduleFinished(ModuleID, ScanSummary)
    case completed(SmartCareReport)
}

/// The combined result of a Smart Care run. `summaries` agree with `findings`:
/// a path reported by two modules is kept once, under whichever reported it first.
public struct SmartCareReport: Sendable, Hashable, Codable {
    public let startedAt: Date
    public let duration: TimeInterval
    public let summaries: [ModuleID: ScanSummary]
    public let findings: [Finding]
    /// Scanner id -> error message.
    public let failures: [String: String]

    public init(startedAt: Date, duration: TimeInterval, summaries: [ModuleID: ScanSummary],
                findings: [Finding], failures: [String: String]) {
        self.startedAt = startedAt
        self.duration = duration
        self.summaries = summaries
        self.findings = findings
        self.failures = failures
    }

    public func findings(in module: ModuleID) -> [Finding] {
        findings.filter { $0.category.module == module }
    }
}

/// Which findings Smart Care's single "Run" acts on.
///
/// Cleanup and Performance findings below `.risky` are selected, as on their own
/// screens. Applications (leftovers, installers), My Clutter (personal files) and
/// Protection (threats, quarantined through `ThreatQuarantine`, never a `Remover`)
/// are review-only: Smart Care shows their totals and links to the module.
public struct SmartCarePolicy: Sendable, Hashable {
    public static let `default` = SmartCarePolicy(autoSelect: [
        .cleanup: [.safe, .caution],
        .performance: [.safe, .caution],
    ])

    public let autoSelect: [ModuleID: Set<RiskLevel>]

    public init(autoSelect: [ModuleID: Set<RiskLevel>]) {
        // `.risky` is never selected without a person ticking it.
        self.autoSelect = autoSelect.mapValues { $0.subtracting([.risky]) }
    }

    public func isSelectedByDefault(_ finding: Finding) -> Bool {
        autoSelect[finding.category.module]?.contains(finding.risk) ?? false
    }

    /// Selected findings, minus any that sit inside another selected folder
    /// (removing the folder removes them; counting both would double the bytes).
    public func defaultSelection(_ report: SmartCareReport) -> [Finding] {
        FindingSelection.droppingNested(report.findings.filter(isSelectedByDefault))
    }

    public func reclaimableBytes(_ report: SmartCareReport) -> Int64 {
        defaultSelection(report).reduce(0) { $0 + $1.sizeBytes }
    }

    /// Modules whose findings are shown for review only.
    public func isReviewOnly(_ module: ModuleID) -> Bool {
        autoSelect[module]?.isEmpty ?? true
    }
}

/// Runs every module's scanners at once: one `ScanCoordinator` per module, all
/// modules concurrently, events merged into one stream. Calling `run` again
/// cancels the previous run.
public actor SmartCareCoordinator {
    private let modules: [(ModuleID, [any CleanerScanner])]
    private let maxConcurrencyPerModule: Int
    private var runningTask: Task<Void, Never>?

    public init(modules: [(ModuleID, [any CleanerScanner])], maxConcurrencyPerModule: Int = 2) {
        self.modules = modules
        self.maxConcurrencyPerModule = max(1, maxConcurrencyPerModule)
    }

    /// `.moduleStarted` for every module comes first, in `modules` order. The
    /// stream always ends with `.completed`, also after `cancel()`, carrying
    /// whatever was found until then.
    public func run(_ context: ScanContext) -> AsyncStream<SmartCareEvent> {
        runningTask?.cancel()
        let (stream, continuation) = AsyncStream<SmartCareEvent>.makeStream(bufferingPolicy: .unbounded)
        let modules = self.modules
        let concurrency = maxConcurrencyPerModule
        let task = Task.detached(priority: .utility) {
            await Self.execute(modules: modules, concurrency: concurrency,
                               context: context, continuation: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        runningTask = task
        return stream
    }

    public func cancel() {
        runningTask?.cancel()
    }

    private static func execute(modules: [(ModuleID, [any CleanerScanner])], concurrency: Int,
                                context: ScanContext,
                                continuation: AsyncStream<SmartCareEvent>.Continuation) async {
        let startedAt = Date.now
        let clock = ContinuousClock()
        let start = clock.now
        let merger = SmartCareMerger(continuation: continuation)
        for (module, scanners) in modules {
            await merger.start(module, scannerIDs: scanners.map { type(of: $0).id })
        }

        await withTaskGroup(of: Void.self) { group in
            for (module, scanners) in modules {
                group.addTask {
                    let coordinator = ScanCoordinator(scanners: scanners, maxConcurrency: concurrency)
                    // A cancelled task ends this loop early (AsyncStream returns nil),
                    // which also cancels the module's coordinator via onTermination.
                    for await event in await coordinator.run(context) {
                        await merger.handle(event, module: module)
                    }
                    await merger.finish(module)
                }
            }
            await group.waitForAll()
        }

        let report = await merger.report(startedAt: startedAt, duration: seconds(clock.now - start))
        continuation.yield(.completed(report))
        continuation.finish()
    }
}

func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Serializes the merged stream and owns cross-module de-duplication and totals.
private actor SmartCareMerger {
    private struct ModuleState {
        var scannerIDs: [String]
        var fractions: [String: Double] = [:]
        var finished: Set<String> = []
        var count = 0
        var bytes: Int64 = 0
        var byCategory: [String: Int64] = [:]
        var duration: TimeInterval?
        var started = ContinuousClock.now
        var isDone = false
    }

    private let continuation: AsyncStream<SmartCareEvent>.Continuation
    private var states: [ModuleID: ModuleState] = [:]
    private var order: [ModuleID] = []
    private var seen: Set<String> = []
    private var findings: [Finding] = []
    private var failures: [String: String] = [:]

    init(continuation: AsyncStream<SmartCareEvent>.Continuation) {
        self.continuation = continuation
    }

    func start(_ module: ModuleID, scannerIDs: [String]) {
        states[module] = ModuleState(scannerIDs: scannerIDs)
        order.append(module)
        continuation.yield(.moduleStarted(module))
    }

    func handle(_ event: ScanEvent, module: ModuleID) {
        guard var state = states[module] else { return }
        switch event {
        case .started:
            break
        case .progress(let scannerID, let fraction):
            if let fraction { state.fractions[scannerID] = fraction }
        case .finding(let finding):
            if seen.insert(finding.path.standardizedFileURL.path).inserted {
                findings.append(finding)
                state.count += 1
                state.bytes += finding.sizeBytes
                state.byCategory[finding.category.id, default: 0] += finding.sizeBytes
                continuation.yield(.finding(module, finding))
            }
        case .finished(let scannerID, _, _):
            state.finished.insert(scannerID)
        case .failed(let scannerID, let message):
            state.finished.insert(scannerID)
            failures[scannerID] = message
            continuation.yield(.scannerFailed(module, scannerID: scannerID, message: message))
        case .completed(let summary):
            state.duration = summary.duration
        }
        states[module] = state
        if case .finding = event { return }
        continuation.yield(.moduleProgress(module, fraction: Self.fraction(state)))
    }

    func finish(_ module: ModuleID) {
        guard var state = states[module], !state.isDone else { return }
        state.isDone = true
        if state.duration == nil {
            state.duration = seconds(ContinuousClock.now - state.started)
        }
        states[module] = state
        continuation.yield(.moduleFinished(module, Self.summary(state)))
    }

    func report(startedAt: Date, duration: TimeInterval) -> SmartCareReport {
        var summaries: [ModuleID: ScanSummary] = [:]
        for module in order {
            if let state = states[module] { summaries[module] = Self.summary(state) }
        }
        return SmartCareReport(startedAt: startedAt, duration: duration, summaries: summaries,
                               findings: findings, failures: failures)
    }

    private static func summary(_ state: ModuleState) -> ScanSummary {
        ScanSummary(totalFindings: state.count, totalBytes: state.bytes,
                    byCategory: state.byCategory, duration: state.duration ?? 0)
    }

    /// Mean of per-scanner fractions (finished = 1); nil until any is known.
    private static func fraction(_ state: ModuleState) -> Double? {
        guard !state.scannerIDs.isEmpty else { return 1 }
        var total = 0.0
        var known = false
        for id in state.scannerIDs {
            if state.finished.contains(id) {
                total += 1
                known = true
            } else if let fraction = state.fractions[id] {
                total += fraction
                known = true
            }
        }
        return known ? min(total / Double(state.scannerIDs.count), 1) : nil
    }
}

public enum FindingSelection {
    /// Drops findings whose path is inside another finding's path, keeping order.
    public static func droppingNested(_ findings: [Finding]) -> [Finding] {
        let paths = Set(findings.map { $0.path.standardizedFileURL.path })
        return findings.filter { finding in
            var ancestor = finding.path.standardizedFileURL
            while ancestor.pathComponents.count > 1 {
                ancestor = ancestor.deletingLastPathComponent()
                if paths.contains(ancestor.path) { return false }
            }
            return true
        }
    }
}
