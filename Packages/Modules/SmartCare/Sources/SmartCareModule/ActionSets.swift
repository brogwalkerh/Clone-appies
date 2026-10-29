import Foundation
import CleanerCore
import PerformanceModule

/// One step of a My Tools action set (PLAN.md §3.12).
public enum ActionStep: Codable, Sendable, Hashable {
    /// Scan with these scanners, then remove the `.safe` findings (plus
    /// `.caution` ones when asked). `.risky` findings are never removed
    /// without a person ticking them, so they are skipped here.
    case clean(scannerIDs: [String], includeCaution: Bool)
    /// A `MaintenanceCatalog` task id.
    case maintenance(taskID: String)
}

/// A named sequence of steps, run with one click or on a schedule.
public struct ActionSet: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var steps: [ActionStep]
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, steps: [ActionStep], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.steps = steps
        self.createdAt = createdAt
    }

    /// Human-readable problems; empty when the set can run.
    public func validate(knownScannerIDs: Set<String>, knownTaskIDs: Set<String>) -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The action set needs a name.")
        }
        if steps.isEmpty {
            problems.append("Add at least one step.")
        }
        for (index, step) in steps.enumerated() {
            switch step {
            case .clean(let ids, _):
                if ids.isEmpty {
                    problems.append("Step \(index + 1) does not choose anything to clean.")
                }
                for id in ids where !knownScannerIDs.contains(id) {
                    problems.append("Step \(index + 1) uses an unknown scanner '\(id)'.")
                }
            case .maintenance(let taskID):
                if !knownTaskIDs.contains(taskID) {
                    problems.append("Step \(index + 1) uses an unknown maintenance task '\(taskID)'.")
                }
            }
        }
        return problems
    }
}

/// Starter sets offered in My Tools. Ids are fixed so a user's copy can be
/// told apart from the preset.
public enum ActionSetPresets {
    static let epoch = Date(timeIntervalSince1970: 1_793_232_000)   // 2026-10-29

    /// 6F1D2C3B-0001-4A5B-9C8D-0000000000NN
    static func presetID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x6F, 0x1D, 0x2C, 0x3B, 0x00, 0x01, 0x4A, 0x5B, 0x9C, 0x8D, 0, 0, 0, 0, 0, n))
    }

    public static let fridayClean = ActionSet(
        id: presetID(1),
        name: "Friday clean",
        steps: [
            .clean(scannerIDs: ["cleanup.userCaches", "cleanup.logs", "cleanup.trash"], includeCaution: false),
            .maintenance(taskID: "maintenance.freeRAM"),
        ],
        createdAt: epoch)

    public static let developerCleanup = ActionSet(
        id: presetID(2),
        name: "Developer cleanup",
        steps: [
            .clean(scannerIDs: ["cleanup.xcode", "cleanup.devCaches", "cleanup.aiLeftovers"], includeCaution: false),
        ],
        createdAt: epoch)

    public static let quickTuneUp = ActionSet(
        id: presetID(3),
        name: "Quick tune-up",
        steps: [
            .maintenance(taskID: "maintenance.freeRAM"),
            .maintenance(taskID: "maintenance.flushDNS"),
            .clean(scannerIDs: ["cleanup.brokenDownloads"], includeCaution: false),
        ],
        createdAt: epoch)

    public static let all: [ActionSet] = [fridayClean, developerCleanup, quickTuneUp]
}

public struct ActionStepResult: Sendable, Hashable {
    public let index: Int
    public let step: ActionStep
    public let succeeded: Bool
    public let message: String
    public let bytesReclaimed: Int64
    public let manifest: RemovalManifest?
    public let maintenance: MaintenanceResult?

    public init(index: Int, step: ActionStep, succeeded: Bool, message: String, bytesReclaimed: Int64 = 0,
                manifest: RemovalManifest? = nil, maintenance: MaintenanceResult? = nil) {
        self.index = index
        self.step = step
        self.succeeded = succeeded
        self.message = message
        self.bytesReclaimed = bytesReclaimed
        self.manifest = manifest
        self.maintenance = maintenance
    }
}

public struct ActionSetReport: Sendable, Hashable {
    public let actionSetID: UUID
    public let results: [ActionStepResult]

    public init(actionSetID: UUID, results: [ActionStepResult]) {
        self.actionSetID = actionSetID
        self.results = results
    }

    public var bytesReclaimed: Int64 {
        results.reduce(0) { $0 + $1.bytesReclaimed }
    }

    public var succeeded: Bool {
        results.allSatisfy { $0.succeeded }
    }
}

public enum ActionSetEvent: Sendable {
    case stepStarted(index: Int, ActionStep)
    case stepFinished(ActionStepResult)
    case completed(ActionSetReport)
}

/// Runs an action set's steps in order. A failing step is recorded and the
/// next one still runs. Removal goes through `remover` (callers pass a
/// `GuardedRemover`) with `removalMode`; a dry run scans but never removes or
/// runs maintenance.
public struct ActionSetRunner: Sendable {
    private let scanners: [any CleanerScanner]
    private let remover: any Remover
    private let maintenance: MaintenanceRunner?
    private let removalMode: RemovalMode
    private let dryRun: Bool

    public init(scanners: [any CleanerScanner], remover: any Remover, maintenance: MaintenanceRunner?,
                removalMode: RemovalMode = .trash, dryRun: Bool = false) {
        self.scanners = scanners
        self.remover = remover
        self.maintenance = maintenance
        self.removalMode = removalMode
        self.dryRun = dryRun
    }

    public func run(_ set: ActionSet, context: ScanContext) -> AsyncStream<ActionSetEvent> {
        let (stream, continuation) = AsyncStream<ActionSetEvent>.makeStream(bufferingPolicy: .unbounded)
        let runner = self
        let task = Task {
            var results: [ActionStepResult] = []
            for (index, step) in set.steps.enumerated() {
                if Task.isCancelled {
                    results.append(ActionStepResult(index: index, step: step, succeeded: false, message: "Cancelled."))
                    continue
                }
                continuation.yield(.stepStarted(index: index, step))
                let result = await runner.perform(step, index: index, context: context)
                results.append(result)
                continuation.yield(.stepFinished(result))
            }
            continuation.yield(.completed(ActionSetReport(actionSetID: set.id, results: results)))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func perform(_ step: ActionStep, index: Int, context: ScanContext) async -> ActionStepResult {
        switch step {
        case .clean(let ids, let includeCaution):
            return await clean(ids, includeCaution: includeCaution, step: step, index: index, context: context)
        case .maintenance(let taskID):
            return await runMaintenance(taskID, step: step, index: index)
        }
    }

    private func clean(_ ids: [String], includeCaution: Bool, step: ActionStep, index: Int,
                       context: ScanContext) async -> ActionStepResult {
        let known = Set(scanners.map { type(of: $0).id })
        let unknown = ids.filter { !known.contains($0) }
        guard unknown.isEmpty, !ids.isEmpty else {
            let message = ids.isEmpty ? "Nothing to clean was chosen."
                                      : "Unknown scanner: \(unknown.joined(separator: ", "))."
            return ActionStepResult(index: index, step: step, succeeded: false, message: message)
        }
        let wanted = Set(ids)
        let chosen = scanners.filter { wanted.contains(type(of: $0).id) }

        var findings: [Finding] = []
        var failures: [String] = []
        for await event in await ScanCoordinator(scanners: chosen).run(context) {
            switch event {
            case .finding(let finding): findings.append(finding)
            case .failed(let scannerID, let message): failures.append("\(scannerID): \(message)")
            default: break
            }
        }
        let allowed: Set<RiskLevel> = includeCaution ? [.safe, .caution] : [.safe]
        let targets = findings.filter { allowed.contains($0.risk) }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let failureNote = failures.isEmpty ? "" : " Scan errors: \(failures.joined(separator: "; "))."

        if targets.isEmpty {
            return ActionStepResult(index: index, step: step, succeeded: failures.isEmpty,
                                    message: "Nothing to clean." + failureNote)
        }
        if dryRun {
            return ActionStepResult(index: index, step: step, succeeded: failures.isEmpty,
                                    message: "Would remove \(Self.items(targets.count)) (\(ByteFormatter.string(bytes)))."
                                        + failureNote)
        }
        do {
            let manifest = try await remover.remove(targets, mode: removalMode, progress: nil)
            let removed = manifest.records.filter(\.succeeded).count
            let failed = manifest.records.count - removed
            var message = "Removed \(Self.items(removed)) (\(ByteFormatter.string(manifest.bytesReclaimed)))."
            if failed > 0 { message += " \(Self.items(failed)) could not be removed." }
            return ActionStepResult(index: index, step: step, succeeded: failed == 0 && failures.isEmpty,
                                    message: message + failureNote, bytesReclaimed: manifest.bytesReclaimed,
                                    manifest: manifest)
        } catch {
            return ActionStepResult(index: index, step: step, succeeded: false,
                                    message: "Removal failed: \(error)")
        }
    }

    private func runMaintenance(_ taskID: String, step: ActionStep, index: Int) async -> ActionStepResult {
        guard let task = MaintenanceCatalog.task(id: taskID) else {
            return ActionStepResult(index: index, step: step, succeeded: false,
                                    message: "Unknown maintenance task '\(taskID)'.")
        }
        if dryRun {
            return ActionStepResult(index: index, step: step, succeeded: true, message: "Would run \(task.name).")
        }
        guard let maintenance else {
            return ActionStepResult(index: index, step: step, succeeded: false,
                                    message: "\(task.name) is not available here.")
        }
        let result = await maintenance.run(task)
        return ActionStepResult(index: index, step: step, succeeded: result.succeeded,
                                message: result.message, bytesReclaimed: max(result.bytesReclaimed ?? 0, 0),
                                maintenance: result)
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
