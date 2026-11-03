import ArgumentParser
import Foundation
import CleanerCore
import PerformanceModule
import SmartCareModule

struct ActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "List and run My Tools action sets (built-in presets plus the ones made in the app).",
        subcommands: [ActionsListCommand.self, ActionsRunCommand.self])
}

struct ActionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List action sets and their steps.")

    @Flag(name: .long, help: "Print the list as a JSON array.")
    var json = false

    @OptionGroup var history: HistoryOptions

    func run() async throws {
        try ActionSets.list(ActionSets.available(storage: history.storage), json: json, io: .standard)
    }
}

struct ActionsRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an action set by name or id. Removes .safe findings to the Trash; helper tasks are skipped.")

    @Argument(help: "Action set name (case-insensitive) or id.")
    var nameOrID: String

    @Option(name: .long, help: "Home directory to scan (default: the current user's home).")
    var home: String?

    @Flag(name: .long, help: "Scan and report without removing anything or running maintenance.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    @OptionGroup var history: HistoryOptions

    func run() async throws {
        let set = try ActionSets.find(nameOrID, in: ActionSets.available(storage: history.storage))
        let homeURL = home.map { fileURL(fromArgument: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let runner = ActionSetRunner(
            scanners: ScannerRegistry.builtIn().scanners,
            remover: GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default),
            maintenance: MaintenanceRunner(commands: ProcessCommandRunner(), helper: nil, home: homeURL),
            dryRun: dryRun)
        let context = ScanContext(fileSystem: LocalFileSystem(), home: homeURL)
        let report = try await ActionSets.run(set, runner: runner, context: context, assumeYes: yes || dryRun,
                                              activity: dryRun ? nil : history.activity,
                                              confirm: { promptForConfirmation() }, io: .standard)
        if let report, !report.succeeded { throw ExitCode(2) }
    }
}

/// Testable core of `actions`.
enum ActionSets {
    /// Presets first, then the app's saved sets (a saved copy of a preset replaces it).
    static func available(storage: SmartCareStorage) -> [ActionSet] {
        let saved = storage.actionSets.load() ?? []
        let savedIDs = Set(saved.map(\.id))
        return ActionSetPresets.all.filter { !savedIDs.contains($0.id) } + saved
    }

    static func find(_ nameOrID: String, in sets: [ActionSet]) throws -> ActionSet {
        let wanted = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: wanted), let set = sets.first(where: { $0.id == id }) { return set }
        if let set = sets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return set }
        throw ValidationError("No action set named '\(nameOrID)'. Available: \(sets.map(\.name).joined(separator: ", "))")
    }

    static func describe(_ step: ActionStep) -> String {
        switch step {
        case .clean(let ids, let includeCaution):
            return "clean \(ids.joined(separator: ", "))\(includeCaution ? " (including caution)" : "")"
        case .maintenance(let taskID):
            let task = MaintenanceCatalog.task(id: taskID)
            let helper = task?.requiresHelper == true ? " (needs the app's helper)" : ""
            return "run \(task?.name ?? taskID)\(helper)"
        }
    }

    static func list(_ sets: [ActionSet], json: Bool, io: CommandIO) throws {
        if json {
            io.out.write(try ScanJSON.encode(sets))
            return
        }
        for set in sets {
            io.out.write("\(set.name)  [\(set.id.uuidString)]")
            for (index, step) in set.steps.enumerated() {
                io.out.write("  \(index + 1). \(describe(step))")
            }
        }
    }

    /// Returns nil when the user declines.
    static func run(_ set: ActionSet, runner: ActionSetRunner, context: ScanContext, assumeYes: Bool,
                    activity: (any ActivityStore)?, confirm: @Sendable () -> Bool,
                    io: CommandIO) async throws -> ActionSetReport? {
        io.out.write("Action set: \(set.name)")
        for (index, step) in set.steps.enumerated() {
            io.out.write("  \(index + 1). \(describe(step))")
        }
        if !assumeYes {
            io.out.write("Safe findings are moved to the Trash; items already in the Trash are deleted.")
            guard confirm() else {
                io.out.write("Aborted.")
                return nil
            }
        }

        var report: ActionSetReport?
        for await event in runner.run(set, context: context) {
            switch event {
            case .stepStarted:
                break
            case .stepFinished(let result):
                io.out.write("[\(result.succeeded ? "done" : "failed")] \(result.index + 1). \(result.message)")
            case .completed(let finished):
                report = finished
            }
        }
        guard let report else { return nil }
        io.out.write("Reclaimed \(ByteFormatter.string(report.bytesReclaimed)).")

        var events: [ActivityEvent] = []
        for result in report.results {
            if let manifest = result.manifest { events += ActivityEvent.removals(manifest) }
            if let maintenance = result.maintenance { events.append(.maintenance(maintenance)) }
        }
        events.append(ActivityEvent(kind: .actionSet, module: nil, title: "Ran \(set.name)",
                                    bytes: report.bytesReclaimed, items: report.results.count,
                                    reference: set.id.uuidString))
        await record(events, in: activity, io: io)
        return report
    }
}
