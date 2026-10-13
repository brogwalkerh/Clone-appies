import ArgumentParser
import Foundation
import CleanerCore

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Run the registered scanners against a home directory and report findings.")

    @Option(name: .long, help: "Only run scanners from this module (\(ModuleID.allCases.map(\.rawValue).joined(separator: "|"))).",
            transform: ScanCommand.parseModule)
    var module: ModuleID?

    @Option(name: .long, help: "Only run the scanner with this id (repeatable).")
    var scanner: [String] = []

    @Option(name: .long, help: "Home directory to scan (default: the current user's home).")
    var home: String?

    @Flag(name: .long, help: "Print a JSON document instead of a table; suppresses progress output.")
    var json = false

    @Flag(name: .long, help: "Include findings marked risky (hidden by default).")
    var includeRisky = false

    @Option(name: .long, help: "Maximum number of scanners running at once.")
    var maxConcurrency = 4

    @Flag(name: .long, help: "Exit with status 2 when any scanner fails.")
    var strict = false

    func validate() throws {
        guard maxConcurrency >= 1 else {
            throw ValidationError("--max-concurrency must be at least 1.")
        }
    }

    func run() async throws {
        let scanners = try ScannerRegistry.builtIn().filtered(module: module, scannerIDs: scanner)
        guard !scanners.isEmpty else {
            throw ValidationError("No registered scanner matches the given filters.")
        }
        let context = ScanContext(fileSystem: LocalFileSystem(),
                                  home: home.map { fileURL(fromArgument: $0, isDirectory: true) })
        var options = ScanOptions()
        options.json = json
        options.includeRisky = includeRisky
        options.maxConcurrency = maxConcurrency
        let outcome = await ScanRunner.run(context: context, scanners: scanners,
                                           options: options, io: .standard)
        if strict, !outcome.failures.isEmpty {
            throw ExitCode(2)
        }
    }

    static func parseModule(_ argument: String) throws -> ModuleID {
        guard let module = ModuleID(rawValue: argument.lowercased()) else {
            throw ValidationError("Unknown module '\(argument)'. Expected one of: "
                                  + ModuleID.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return module
    }
}

struct ScanOptions: Sendable {
    var json = false
    var includeRisky = false
    var maxConcurrency = 4
    /// Progress lines go to `io.err`; always suppressed with `json`.
    var showProgress = true
    var topCount = 20
}

struct ScanFailure: Hashable, Sendable {
    let scannerID: String
    let message: String
}

struct ScanOutcome: Sendable {
    /// Findings and a summary consistent with them (risky ones dropped unless requested).
    let document: ScanDocument
    let failures: [ScanFailure]
    let skippedRisky: Int
}

/// Testable core of `scan`: runs the coordinator, streams progress to `io.err`
/// and writes the table or JSON document to `io.out`.
enum ScanRunner {
    static func run(context: ScanContext, scanners: [any CleanerScanner],
                    options: ScanOptions, io: CommandIO) async -> ScanOutcome {
        let coordinator = ScanCoordinator(scanners: scanners, maxConcurrency: options.maxConcurrency)
        let progress = options.showProgress && !options.json
        var findings: [Finding] = []
        var failures: [ScanFailure] = []
        var duration: TimeInterval = 0

        for await event in await coordinator.run(context) {
            switch event {
            case .started(let scannerID):
                if progress { io.err.write("[started]  \(scannerID)") }
            case .finding(let finding):
                findings.append(finding)
            case .progress:
                break
            case .finished(let scannerID, let count, let bytes):
                if progress {
                    io.err.write("[finished] \(scannerID): \(count) finding\(count == 1 ? "" : "s"), \(ByteFormatter.string(bytes))")
                }
            case .failed(let scannerID, let message):
                failures.append(ScanFailure(scannerID: scannerID, message: message))
                if progress { io.err.write("[failed]   \(scannerID): \(message)") }
            case .completed(let summary):
                duration = summary.duration
            }
        }

        let kept = options.includeRisky ? findings : findings.filter { $0.risk != .risky }
        let document = ScanDocument(findings: kept.sortedBySize(), duration: duration)
        let outcome = ScanOutcome(document: document, failures: failures,
                                  skippedRisky: findings.count - kept.count)

        if options.json {
            if let text = try? ScanJSON.encode(document) {
                io.out.write(text)
            } else {
                io.err.write("error: could not encode scan results as JSON")
            }
        } else {
            io.out.write(TableFormatter.render(document, topCount: options.topCount))
            if outcome.skippedRisky > 0 {
                io.out.write("\(outcome.skippedRisky) risky finding\(outcome.skippedRisky == 1 ? "" : "s") hidden (pass --include-risky to show).")
            }
            if !failures.isEmpty {
                io.out.write("\(failures.count) scanner\(failures.count == 1 ? "" : "s") failed; see stderr.")
            }
        }
        return outcome
    }
}
