import ArgumentParser
import Foundation
import CleanerCore
import ProtectionModule
import SmartCareModule

struct SmartCareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smart-care",
        abstract: "Scan every module at once and report what Smart Care would clean; --run moves it to the Trash.")

    @Option(name: .long, help: "Home directory to scan (default: the current user's home).")
    var home: String?

    @Flag(name: .long, help: "Print a JSON document instead of a table (scan only; not with --run).")
    var json = false

    @Flag(name: .long, help: "Remove the selected findings (non-risky Cleanup and Performance) after confirming.")
    var run = false

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    @Flag(name: .customLong("no-malware"), help: "Skip the quick malware scan.")
    var noMalware = false

    @Option(name: .customLong("manifest-out"),
            help: "Where to write the removal manifest (default: ~/.maccleaner/manifests/<uuid>.json).")
    var manifestOut: String?

    @OptionGroup var history: HistoryOptions

    func validate() throws {
        if json, run { throw ValidationError("--json reports a scan; it cannot be combined with --run.") }
    }

    func run() async throws {
        let context = ScanContext(fileSystem: LocalFileSystem(),
                                  home: home.map { fileURL(fromArgument: $0, isDirectory: true) })
        var options = SmartCareOptions()
        options.json = json
        options.remove = run
        options.assumeYes = yes
        options.manifestOut = manifestOut.map { fileURL(fromArgument: $0, isDirectory: false) }
        let modules = SmartCareRun.modules(registry: .builtIn(),
                                           malware: noMalware ? nil : SignatureDatabase.bundledStarter())
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        _ = try await SmartCareRun.run(context: context, modules: modules, options: options, remover: remover,
                                       activity: history.activity, confirm: { promptForConfirmation() },
                                       io: .standard)
    }
}

struct SmartCareOptions: Sendable {
    var json = false
    var remove = false
    var assumeYes = false
    var manifestOut: URL?
    var showProgress = true
    var policy = SmartCarePolicy.default
}

struct SmartCareOutcome: Sendable {
    let report: SmartCareReport
    let selection: [Finding]
    let removal: RemoveOutcome?
}

/// JSON shape of `smart-care --json`.
struct SmartCareDocument: Codable, Hashable, Sendable {
    struct Module: Codable, Hashable, Sendable {
        let module: String
        let findings: Int
        let bytes: Int64
        let reviewOnly: Bool
    }
    let startedAt: Date
    let duration: TimeInterval
    let modules: [Module]
    let reclaimableBytes: Int64
    let selected: [Finding]
    let failures: [String: String]
}

/// Testable core of `smart-care`.
enum SmartCareRun {
    /// Smart Care's display order (PLAN.md §3.1).
    static let order: [ModuleID] = [.cleanup, .protection, .performance, .applications, .clutter]

    /// Registered scanners grouped by module. Privacy cleaners are left out (they
    /// clear history and cookies, which is a choice, not junk) and so is the demo
    /// scanner; the quick malware scan stands for Protection when a database is given.
    static func modules(registry: ScannerRegistry, malware: SignatureDatabase?) -> [(ModuleID, [any CleanerScanner])] {
        order.compactMap { module -> (ModuleID, [any CleanerScanner])? in
            var scanners = registry.scanners.filter {
                $0.module == module && $0.id != DemoScanner.id && !$0.id.hasPrefix("privacy.")
            }
            if module == .protection, let malware {
                scanners.append(MalwareScanner(scope: .quick, database: malware))
            }
            return scanners.isEmpty ? nil : (module, scanners)
        }
    }

    static func run(context: ScanContext, modules: [(ModuleID, [any CleanerScanner])], options: SmartCareOptions,
                    remover: any Remover, activity: (any ActivityStore)?, confirm: @Sendable () -> Bool,
                    io: CommandIO) async throws -> SmartCareOutcome {
        let progress = options.showProgress && !options.json
        var report: SmartCareReport?
        for await event in await SmartCareCoordinator(modules: modules).run(context) {
            switch event {
            case .moduleFinished(let module, let summary) where progress:
                io.err.write("[finished] \(module.displayName): \(count(summary.totalFindings, "finding")), \(ByteFormatter.string(summary.totalBytes))")
            case .scannerFailed(_, let scannerID, let message) where progress:
                io.err.write("[failed]   \(scannerID): \(message)")
            case .completed(let result):
                report = result
            default:
                break
            }
        }
        guard let report else { throw SmartCareError.noReport }
        let selection = options.policy.defaultSelection(report)

        var events = report.summaries.keys.sorted { order.firstIndex(of: $0) ?? 0 < order.firstIndex(of: $1) ?? 0 }
            .compactMap { module in report.summaries[module].map { ActivityEvent.scan($0, module: module, date: report.startedAt) } }

        if options.json {
            io.out.write(try ScanJSON.encode(document(report, selection: selection, policy: options.policy)))
            await record(events, in: activity, io: io)
            return SmartCareOutcome(report: report, selection: selection, removal: nil)
        }

        io.out.write(table(report, policy: options.policy))
        let bytes = selection.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard options.remove else {
            if selection.isEmpty {
                io.out.write("Nothing for Smart Care to clean.")
            } else {
                io.out.write("Smart Care can remove \(ByteFormatter.string(bytes)) now (\(count(selection.count, "item"))). "
                             + "Run `maccleaner smart-care --run` to move them to the Trash.")
            }
            await record(events, in: activity, io: io)
            return SmartCareOutcome(report: report, selection: selection, removal: nil)
        }

        var removeOptions = RemoveOptions()
        removeOptions.assumeYes = options.assumeYes
        removeOptions.manifestOut = options.manifestOut
        let removal = try await RemoveRunner.run(document: ScanDocument(findings: selection, duration: report.duration),
                                                 options: removeOptions, remover: remover, confirm: confirm, io: io)
        if let manifest = removal.manifest {
            events += ActivityEvent.removals(manifest)
        }
        await record(events, in: activity, io: io)
        return SmartCareOutcome(report: report, selection: selection, removal: removal)
    }

    static func table(_ report: SmartCareReport, policy: SmartCarePolicy) -> String {
        var lines = ["Smart Care (\(String(format: "%.1f", report.duration)) s)"]
        let rows = order.compactMap { module -> (ModuleID, ScanSummary)? in
            report.summaries[module].map { (module, $0) }
        }
        let nameWidth = rows.map { $0.0.displayName.count }.max() ?? 0
        let countWidth = rows.map { String($0.1.totalFindings).count }.max() ?? 0
        for (module, summary) in rows {
            let name = module.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let number = TableFormatter.padLeft(String(summary.totalFindings), to: countWidth)
            let noun = module == .protection ? (summary.totalFindings == 1 ? "threat " : "threats") : (summary.totalFindings == 1 ? "item " : "items")
            var line = "  \(name)  \(number) \(noun)"
            if module != .protection { line += "  \(ByteFormatter.string(summary.totalBytes))" }
            if policy.isReviewOnly(module), summary.totalFindings > 0 {
                line += module == .protection ? "  (quarantine with `maccleaner protect scan`)" : "  (review in the app)"
            }
            lines.append(line)
        }
        if !report.failures.isEmpty {
            lines.append("\(count(report.failures.count, "scanner")) failed; see stderr.")
        }
        return lines.joined(separator: "\n")
    }

    static func document(_ report: SmartCareReport, selection: [Finding], policy: SmartCarePolicy) -> SmartCareDocument {
        SmartCareDocument(
            startedAt: report.startedAt,
            duration: report.duration,
            modules: order.compactMap { module in
                report.summaries[module].map {
                    SmartCareDocument.Module(module: module.rawValue, findings: $0.totalFindings,
                                             bytes: $0.totalBytes, reviewOnly: policy.isReviewOnly(module))
                }
            },
            reclaimableBytes: selection.reduce(0) { $0 + $1.sizeBytes },
            selected: selection.sortedBySize(),
            failures: report.failures)
    }

    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

enum SmartCareError: Error, CustomStringConvertible {
    case noReport
    var description: String { "The Smart Care run ended without a report." }
}
