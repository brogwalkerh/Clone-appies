import ArgumentParser
import Foundation
import CleanerCore

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the findings listed in a scan JSON document (Trash first; undo via the manifest).")

    @Option(name: .customLong("from-json"), help: "Scan document produced by `maccleaner scan --json`.")
    var fromJSON: String

    @Option(name: .long, help: "trash (default) or permanent. Permanent removal requires --yes.",
            transform: RemoveCommand.parseMode)
    var mode: RemovalMode = .trash

    @Flag(name: .long, help: "List what would be removed without touching anything.")
    var dryRun = false

    @Flag(name: .long, help: "Also remove findings marked risky (skipped by default).")
    var includeRisky = false

    @Option(name: .customLong("manifest-out"),
            help: "Where to write the removal manifest (default: ~/.maccleaner/manifests/<uuid>.json).")
    var manifestOut: String?

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    func run() async throws {
        let document = try ScanJSON.decode(ScanDocument.self, from: fileURL(fromArgument: fromJSON, isDirectory: false))
        var options = RemoveOptions()
        options.mode = mode
        options.dryRun = dryRun
        options.includeRisky = includeRisky
        options.assumeYes = yes
        options.manifestOut = manifestOut.map { fileURL(fromArgument: $0, isDirectory: false) }
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        _ = try await RemoveRunner.run(document: document, options: options, remover: remover,
                                       confirm: RemoveCommand.promptForConfirmation, io: .standard)
    }

    static func parseMode(_ argument: String) throws -> RemovalMode {
        guard let mode = RemovalMode(rawValue: argument.lowercased()) else {
            throw ValidationError("Unknown mode '\(argument)'. Expected trash or permanent.")
        }
        return mode
    }

    /// Asks `Proceed? [y/N]` on the terminal; anything but y/yes declines.
    @Sendable
    static func promptForConfirmation() -> Bool {
        FileHandle.standardOutput.write(Data("Proceed? [y/N] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return answer == "y" || answer == "yes"
    }
}

struct RemoveOptions: Sendable {
    var mode: RemovalMode = .trash
    var dryRun = false
    var includeRisky = false
    var assumeYes = false
    /// nil means `~/.maccleaner/manifests/<manifest id>.json`.
    var manifestOut: URL?
}

struct RemoveOutcome: Sendable {
    let selected: [Finding]
    let skippedRisky: Int
    let skippedNested: Int
    /// nil for a dry run or a declined confirmation.
    let manifest: RemovalManifest?
    let manifestURL: URL?
}

enum RemoveError: Error, Hashable, CustomStringConvertible {
    case permanentRequiresYes

    var description: String {
        switch self {
        case .permanentRequiresYes:
            return "--mode permanent bypasses the Trash and cannot be undone; pass --yes to confirm."
        }
    }
}

/// Testable core of `remove`.
enum RemoveRunner {
    /// Risky findings are dropped unless requested, and so is any finding that
    /// lives under another selected finding (removing the parent takes it along;
    /// removing it separately would only fail with "not found").
    static func selectFindings(from document: ScanDocument, includeRisky: Bool)
        -> (selected: [Finding], skippedRisky: Int, skippedNested: Int) {
        let sorted = document.findings.sortedBySize()
        let unrisky = includeRisky ? sorted : sorted.filter { $0.risk != .risky }
        let selected = droppingNested(unrisky)
        return (selected, sorted.count - unrisky.count, unrisky.count - selected.count)
    }

    /// Removes findings whose path has an ancestor in the same list.
    static func droppingNested(_ findings: [Finding]) -> [Finding] {
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

    static func defaultManifestURL(for id: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".maccleaner/manifests", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    static func run(document: ScanDocument, options: RemoveOptions, remover: any Remover,
                    confirm: @Sendable () -> Bool, io: CommandIO) async throws -> RemoveOutcome {
        if options.mode == .permanent, !options.assumeYes, !options.dryRun {
            throw RemoveError.permanentRequiresYes
        }

        let (selected, skippedRisky, skippedNested) = selectFindings(from: document, includeRisky: options.includeRisky)
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let verb = options.mode == .trash ? "move to Trash" : "permanently delete"

        io.out.write("Would \(verb) \(selected.count) item\(selected.count == 1 ? "" : "s") (\(ByteFormatter.string(totalBytes))):")
        let sizeWidth = selected.map { ByteFormatter.string($0.sizeBytes).count }.max() ?? 0
        for finding in selected {
            let size = TableFormatter.padLeft(ByteFormatter.string(finding.sizeBytes), to: sizeWidth)
            io.out.write("  \(finding.risk.badge) \(size)  \(finding.path.path)\(finding.isDirectory ? "/" : "")")
        }
        if skippedRisky > 0 {
            io.out.write("Skipped \(skippedRisky) risky finding\(skippedRisky == 1 ? "" : "s") (pass --include-risky to include them).")
        }
        if skippedNested > 0 {
            io.out.write("Skipped \(skippedNested) finding\(skippedNested == 1 ? "" : "s") nested under other selected items.")
        }

        if options.dryRun {
            io.out.write("Dry run: nothing was removed.")
            return RemoveOutcome(selected: selected, skippedRisky: skippedRisky, skippedNested: skippedNested,
                                 manifest: nil, manifestURL: nil)
        }
        if selected.isEmpty {
            io.out.write("Nothing to remove.")
            return RemoveOutcome(selected: selected, skippedRisky: skippedRisky, skippedNested: skippedNested,
                                 manifest: nil, manifestURL: nil)
        }
        if !options.assumeYes, !confirm() {
            io.out.write("Aborted.")
            return RemoveOutcome(selected: selected, skippedRisky: skippedRisky, skippedNested: skippedNested,
                                 manifest: nil, manifestURL: nil)
        }

        let manifest = try await remover.remove(selected, mode: options.mode, progress: nil)
        let manifestURL = options.manifestOut ?? defaultManifestURL(for: manifest.id)
        try ScanJSON.write(manifest, to: manifestURL)

        let succeeded = manifest.records.filter(\.succeeded).count
        let failed = manifest.records.count - succeeded
        io.out.write("Removed \(succeeded) of \(manifest.records.count) item\(manifest.records.count == 1 ? "" : "s"), reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).")
        for record in manifest.records where !record.succeeded {
            io.err.write("[failed]   \(record.finding.path.path): \(record.error ?? "unknown error")")
        }
        if failed > 0 {
            io.out.write("\(failed) item\(failed == 1 ? "" : "s") could not be removed; see stderr.")
        }
        io.out.write("Manifest written to \(manifestURL.path)")
        if options.mode == .trash {
            io.out.write("Undo with: maccleaner undo --manifest \(manifestURL.path)")
        }
        return RemoveOutcome(selected: selected, skippedRisky: skippedRisky, skippedNested: skippedNested,
                             manifest: manifest, manifestURL: manifestURL)
    }
}
