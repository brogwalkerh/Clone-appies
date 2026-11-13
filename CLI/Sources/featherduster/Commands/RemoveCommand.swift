import ArgumentParser
import Foundation
import CleanerCore
import SmartCareModule

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the findings listed in a scan JSON document (Trash first; undo via the manifest).",
        discussion: """
            Items that already are in the Trash are deleted permanently (that is what emptying \
            the Trash means) and cannot be restored with `undo`. Exits with status 1 when any \
            item could not be removed.
            """)

    @Option(name: .customLong("from-json"), help: "Scan document produced by `featherduster scan --json`.")
    var fromJSON: String

    @Option(name: .long, help: "trash (default) or permanent. Permanent removal requires --yes.",
            transform: RemoveCommand.parseMode)
    var mode: RemovalMode = .trash

    @Flag(name: .long, help: "List what would be removed without touching anything.")
    var dryRun = false

    @Flag(name: .long, help: "Also remove findings marked risky (skipped by default).")
    var includeRisky = false

    @Option(name: .customLong("manifest-out"),
            help: "Where to write the removal manifest (default: ~/.featherduster/manifests/<uuid>.json).")
    var manifestOut: String?

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    @OptionGroup var history: HistoryOptions

    func run() async throws {
        let document = try ScanJSON.decode(ScanDocument.self, from: fileURL(fromArgument: fromJSON, isDirectory: false))
        var options = RemoveOptions()
        options.mode = mode
        options.dryRun = dryRun
        options.includeRisky = includeRisky
        options.assumeYes = yes
        options.manifestOut = manifestOut.map { fileURL(fromArgument: $0, isDirectory: false) }
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        let outcome = try await RemoveRunner.run(document: document, options: options, remover: remover,
                                                 activity: history.activity,
                                                 confirm: { promptForConfirmation() }, io: .standard)
        if outcome.failedCount > 0 { throw ExitCode(1) }
    }

    static func parseMode(_ argument: String) throws -> RemovalMode {
        guard let mode = RemovalMode(rawValue: argument.lowercased()) else {
            throw ValidationError("Unknown mode '\(argument)'. Expected trash or permanent.")
        }
        return mode
    }

}

struct RemoveOptions: Sendable {
    var mode: RemovalMode = .trash
    var dryRun = false
    var includeRisky = false
    var assumeYes = false
    /// nil means `~/.featherduster/manifests/<manifest id>.json`.
    var manifestOut: URL?
    /// Home whose `.Trash` the remover empties instead of moving into; nil is
    /// the current user's (what `TrashRemover()` uses).
    var trashHome: URL?
}

struct RemoveOutcome: Sendable {
    let selected: [Finding]
    let skippedRisky: Int
    let skippedNested: Int
    /// nil for a dry run or a declined confirmation.
    let manifest: RemovalManifest?
    let manifestURL: URL?

    /// Records that could not be removed; commands exit non-zero when this is not 0.
    var failedCount: Int {
        manifest?.records.lazy.filter { !$0.succeeded }.count ?? 0
    }
}

/// Mirrors `TrashRemover`'s rule for "already in a Trash": such findings are
/// deleted for good even in `.trash` mode, so the CLI must say so up front.
enum TrashLocations {
    static func isInsideTrash(_ url: URL, home: URL?) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        var roots = [(home ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".Trash", isDirectory: true)]
        #if !canImport(Darwin)
        // Where `TrashRemover()` moves things on Linux (XDG `Trash/files` + `Trash/info`).
        let environment = ProcessInfo.processInfo.environment
        let dataHome: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            dataHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        }
        roots.append(dataHome.appendingPathComponent("Trash", isDirectory: true))
        #endif
        for root in roots {
            let prefix = root.standardizedFileURL.pathComponents
            if path.count > prefix.count, Array(path.prefix(prefix.count)) == prefix { return true }
        }
        // /Volumes/<name>/.Trashes/<uid>/<item>
        return path.count > 5 && path[1] == "Volumes" && path[3] == ".Trashes"
    }
}

enum RemoveError: Error, Hashable, CustomStringConvertible {
    case permanentRequiresYes
    case manifestNotWritable(path: String, reason: String)

    var description: String {
        switch self {
        case .permanentRequiresYes:
            return "--mode permanent bypasses the Trash and cannot be undone; pass --yes to confirm."
        case .manifestNotWritable(let path, let reason):
            return "The removal manifest cannot be written to \(path) (\(reason)). Nothing was removed: "
                + "without a manifest the removal could not be undone. Pass a writable --manifest-out."
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
            .appendingPathComponent(".featherduster/manifests", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Findings that `.trash` mode deletes for good because they already are in a Trash.
    static func alreadyInTrash(_ findings: [Finding], options: RemoveOptions) -> [Finding] {
        guard options.mode == .trash else { return [] }
        return findings.filter { TrashLocations.isInsideTrash($0.path, home: options.trashHome) }
    }

    /// nil when nothing in `findings` is already in a Trash.
    static func permanentDeletionWarning(_ findings: [Finding], options: RemoveOptions) -> String? {
        let doomed = alreadyInTrash(findings, options: options)
        guard !doomed.isEmpty else { return nil }
        let bytes = doomed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let subject = doomed.count == 1 ? "1 item is" : "\(doomed.count) items are"
        return "Warning: \(subject) already in the Trash and will be permanently deleted "
            + "(\(ByteFormatter.string(bytes))); this cannot be undone."
    }

    /// Proves the manifest can be written before anything is removed (CLAUDE.md
    /// rule 3: every removal leaves a manifest for undo). Creates the directory
    /// and writes, then deletes, a probe file next to the destination; the
    /// manifest itself is written atomically through the same directory.
    static func ensureManifestWritable(at destination: URL?) throws {
        let fm = FileManager.default
        let directory = (destination?.deletingLastPathComponent() ?? defaultManifestURL(for: UUID()).deletingLastPathComponent())
        let shown = destination?.path ?? directory.path
        var isDirectory: ObjCBool = false
        if let destination, fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw RemoveError.manifestNotWritable(path: shown, reason: "it is a directory")
        }
        let probe = directory.appendingPathComponent(".manifest-write-test-\(UUID().uuidString)", isDirectory: false)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            try? fm.removeItem(at: probe)
            throw RemoveError.manifestNotWritable(path: shown, reason: error.localizedDescription)
        }
    }

    /// Writes the manifest to `preferred`, falling back to the default
    /// location and then the temporary directory, so a destination that
    /// stopped being writable during the removal still leaves a manifest.
    static func writeManifest(_ manifest: RemovalManifest, preferred: URL, io: CommandIO) throws -> URL {
        let fallbacks = [defaultManifestURL(for: manifest.id),
                         FileManager.default.temporaryDirectory
                             .appendingPathComponent("featherduster-manifest-\(manifest.id.uuidString).json")]
        var firstError: (any Error)?
        for url in [preferred] + fallbacks.filter({ $0 != preferred }) {
            do {
                try ScanJSON.write(manifest, to: url)
                if url != preferred {
                    io.err.write("warning: could not write the manifest to \(preferred.path); wrote it to \(url.path) instead.")
                }
                return url
            } catch {
                firstError = firstError ?? error
            }
        }
        // Last resort: the manifest on stderr is still enough to undo by hand.
        io.err.write("error: the removal manifest could not be written anywhere; it follows.")
        io.err.write((try? ScanJSON.encode(manifest)) ?? "\(manifest)")
        throw firstError ?? RemoveError.manifestNotWritable(path: preferred.path, reason: "unknown error")
    }

    static func run(document: ScanDocument, options: RemoveOptions, remover: any Remover,
                    activity: (any ActivityStore)? = nil,
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

        if let warning = permanentDeletionWarning(selected, options: options) {
            io.out.write(warning)
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

        // Before touching anything: no manifest, no undo, so no removal.
        try ensureManifestWritable(at: options.manifestOut)

        let manifest = try await remover.remove(selected, mode: options.mode, progress: nil)
        let manifestURL = try writeManifest(manifest,
                                            preferred: options.manifestOut ?? defaultManifestURL(for: manifest.id),
                                            io: io)
        await record(ActivityEvent.removals(manifest), in: activity, io: io)

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
            let permanent = manifest.records.filter { $0.succeeded && $0.trashedTo == nil }.count
            if permanent > 0 {
                io.out.write("\(permanent) item\(permanent == 1 ? " was" : "s were") already in the Trash and "
                             + "\(permanent == 1 ? "was" : "were") permanently deleted; undo cannot restore \(permanent == 1 ? "it" : "them").")
            }
            if permanent < succeeded {
                io.out.write("Undo with: featherduster undo --manifest \(manifestURL.path)")
            }
        }
        return RemoveOutcome(selected: selected, skippedRisky: skippedRisky, skippedNested: skippedNested,
                             manifest: manifest, manifestURL: manifestURL)
    }
}
