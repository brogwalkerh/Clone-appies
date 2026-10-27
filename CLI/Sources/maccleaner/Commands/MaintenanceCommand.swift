import ArgumentParser
import Foundation
import CleanerCore
import PerformanceModule

struct MaintenanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintenance",
        abstract: "List and run maintenance tasks (user-level tasks only; helper tasks need the app).",
        subcommands: [MaintenanceListCommand.self, MaintenanceRunCommand.self])
}

struct MaintenanceListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every maintenance task in the catalog.")

    @Flag(name: .long, help: "Print the list as a JSON array.")
    var json = false

    func run() async throws {
        try MaintenanceList.run(tasks: MaintenanceCatalog.all, json: json, io: .standard)
    }
}

struct MaintenanceRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run one or more maintenance tasks by id. Tasks that need the privileged helper are refused.")

    @Argument(help: "Task ids from `maccleaner maintenance list`.")
    var ids: [String]

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print one JSON document with results; helper tasks are reported as skipped.")
    var json = false

    @Option(name: .long, help: "Home directory `~` expands to in task commands (default: the current user's home).")
    var home: String?

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("Pass at least one task id.") }
    }

    func run() async throws {
        let tasks = try MaintenanceRun.resolve(ids: ids, catalog: MaintenanceCatalog.all)
        let homeURL = home.map { fileURL(fromArgument: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let runner = MaintenanceRunner(commands: ProcessCommandRunner(), helper: nil, home: homeURL)
        var options = MaintenanceRunOptions()
        options.assumeYes = yes
        options.json = json
        let outcome: MaintenanceRunOutcome
        do {
            outcome = try await MaintenanceRun.run(tasks: tasks, runner: runner, options: options,
                                                   confirm: { promptForConfirmation(viaStandardError: json) },
                                                   io: .standard)
        } catch let error as MaintenanceRunError {
            FileHandle.standardError.write(Data("Error: \(error.description)\n".utf8))
            throw ExitCode(2)
        }
        if outcome.results.contains(where: { !$0.succeeded }) {
            throw ExitCode(1)
        }
    }
}

// MARK: - list

/// Testable core of `maintenance list`.
enum MaintenanceList {
    struct Entry: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let requiresHelper: Bool
        let risk: RiskLevel
        let estimatedSeconds: Int
    }

    static func entries(_ tasks: [MaintenanceTask]) -> [Entry] {
        tasks.map {
            Entry(id: $0.id, name: $0.name, requiresHelper: $0.requiresHelper,
                  risk: $0.risk, estimatedSeconds: $0.estimatedSeconds)
        }
    }

    static func render(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "No maintenance tasks." }
        let idWidth = max(2, entries.map { $0.id.count }.max() ?? 0)
        let nameWidth = max(4, entries.map { $0.name.count }.max() ?? 0)
        let helperWidth = 6
        let riskWidth = 7
        var lines: [String] = []
        lines.append(TableFormatter.padRight("ID", to: idWidth) + "  "
                     + TableFormatter.padRight("Name", to: nameWidth) + "  "
                     + TableFormatter.padRight("Helper", to: helperWidth) + "  "
                     + TableFormatter.padRight("Risk", to: riskWidth) + "  Est.")
        lines.append(String(repeating: "-", count: idWidth + nameWidth + helperWidth + riskWidth + 8 + 6))
        for entry in entries {
            lines.append(TableFormatter.padRight(entry.id, to: idWidth) + "  "
                         + TableFormatter.padRight(entry.name, to: nameWidth) + "  "
                         + TableFormatter.padRight(entry.requiresHelper ? "yes" : "no", to: helperWidth) + "  "
                         + TableFormatter.padRight(entry.risk.rawValue, to: riskWidth) + "  "
                         + TableFormatter.padLeft("\(entry.estimatedSeconds) s", to: 6))
        }
        return lines.joined(separator: "\n")
    }

    static func run(tasks: [MaintenanceTask], json: Bool, io: CommandIO) throws {
        let list = entries(tasks)
        if json {
            io.out.write(try ScanJSON.encode(list))
        } else {
            io.out.write(render(list))
        }
    }
}

// MARK: - run

struct MaintenanceRunOptions: Sendable {
    var assumeYes = false
    var json = false
}

struct MaintenanceRunOutcome: Sendable, Hashable {
    let results: [MaintenanceResult]
    /// Helper-only tasks that were not run (JSON mode only; otherwise they are refused).
    let skippedHelperTasks: [MaintenanceTask]
    let aborted: Bool
}

enum MaintenanceRunError: Error, Hashable, CustomStringConvertible {
    case unknownTask(String, available: [String])
    case helperRequired([String])

    var description: String {
        switch self {
        case .unknownTask(let id, let available):
            return "Unknown maintenance task '\(id)'. Available: \(available.joined(separator: ", "))"
        case .helperRequired(let ids):
            return "These tasks need the privileged helper and cannot run from the CLI: "
                + ids.joined(separator: ", ") + ". Run them from the app instead."
        }
    }
}

/// Testable core of `maintenance run`.
enum MaintenanceRun {
    /// The JSON document printed with `--json`.
    struct Report: Codable, Hashable, Sendable {
        struct Skipped: Codable, Hashable, Sendable {
            let id: String
            let reason: String
        }
        let results: [MaintenanceResult]
        let skipped: [Skipped]
    }

    /// Looks ids up in the catalog, keeping the given order and dropping repeats.
    static func resolve(ids: [String], catalog: [MaintenanceTask]) throws -> [MaintenanceTask] {
        var seen = Set<String>()
        var tasks: [MaintenanceTask] = []
        for id in ids where seen.insert(id).inserted {
            guard let task = catalog.first(where: { $0.id == id }) else {
                throw MaintenanceRunError.unknownTask(id, available: catalog.map(\.id))
            }
            tasks.append(task)
        }
        return tasks
    }

    static func run(tasks: [MaintenanceTask], runner: MaintenanceRunner, options: MaintenanceRunOptions,
                    confirm: @Sendable () -> Bool, io: CommandIO) async throws -> MaintenanceRunOutcome {
        let helperTasks = tasks.filter(\.requiresHelper)
        let userTasks = tasks.filter { !$0.requiresHelper }

        if !helperTasks.isEmpty, !options.json {
            throw MaintenanceRunError.helperRequired(helperTasks.map(\.id))
        }

        if !options.json {
            io.out.write("Will run \(userTasks.count) task\(userTasks.count == 1 ? "" : "s"):")
            let idWidth = userTasks.map { $0.id.count }.max() ?? 0
            for task in userTasks {
                io.out.write("  \(TableFormatter.padRight(task.id, to: idWidth))  \(task.name) [\(task.risk.rawValue), ~\(task.estimatedSeconds) s]")
            }
        } else {
            for task in helperTasks {
                io.err.write("[skipped]  \(task.id): requires the privileged helper")
            }
        }

        if userTasks.isEmpty {
            if options.json {
                io.out.write(try ScanJSON.encode(report(results: [], skipped: helperTasks)))
            } else {
                io.out.write("Nothing to run.")
            }
            return MaintenanceRunOutcome(results: [], skippedHelperTasks: helperTasks, aborted: false)
        }

        if !options.assumeYes, !confirm() {
            if options.json {
                io.out.write(try ScanJSON.encode(report(results: [], skipped: helperTasks)))
            } else {
                io.out.write("Aborted.")
            }
            return MaintenanceRunOutcome(results: [], skippedHelperTasks: helperTasks, aborted: true)
        }

        var results: [MaintenanceResult] = []
        for await result in await runner.run(userTasks) {
            results.append(result)
            let line = "\(result.succeeded ? "[ok]      " : "[failed]  ")\(result.taskID): \(result.message)"
                + (result.bytesReclaimed.map { ", reclaimed \(ByteFormatter.string($0))" } ?? "")
                + String(format: " (%.1f s)", result.duration)
            if options.json {
                io.err.write(line)
            } else {
                io.out.write(line)
            }
        }

        if options.json {
            io.out.write(try ScanJSON.encode(report(results: results, skipped: helperTasks)))
        } else {
            let failed = results.filter { !$0.succeeded }.count
            io.out.write("\(results.count - failed) of \(results.count) task\(results.count == 1 ? "" : "s") succeeded.")
        }
        return MaintenanceRunOutcome(results: results, skippedHelperTasks: helperTasks, aborted: false)
    }

    private static func report(results: [MaintenanceResult], skipped: [MaintenanceTask]) -> Report {
        Report(results: results,
               skipped: skipped.map { Report.Skipped(id: $0.id, reason: "requires the privileged helper") })
    }
}
