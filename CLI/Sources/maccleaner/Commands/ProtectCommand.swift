import ArgumentParser
import Foundation
import CleanerCore
import ProtectionModule

struct ProtectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "protect",
        abstract: "Malware scanning, quarantine and signature updates.",
        subcommands: [ProtectScanCommand.self, ProtectQuarantineCommand.self, ProtectRestoreCommand.self,
                      ProtectUpdateCommand.self, ProtectSigsCommand.self])
}

// MARK: - Shared

/// A `SignatureDatabase.Stats` mirror that can be written to JSON.
struct SignatureStats: Codable, Hashable, Sendable {
    let hashSignatures: Int
    let patternSignatures: Int
    let allowlisted: Int
    let skippedLines: Int

    init(_ stats: SignatureDatabase.Stats) {
        hashSignatures = stats.hashSignatures
        patternSignatures = stats.patternSignatures
        allowlisted = stats.allowlisted
        skippedLines = stats.skippedLines
    }

    var summary: String {
        "\(hashSignatures) hash, \(patternSignatures) pattern, \(allowlisted) allowlisted"
    }
}

/// The JSON document `protect scan --json` prints and `protect quarantine --from-json` reads.
struct ThreatScanDocument: Codable, Hashable, Sendable {
    let scope: ScanScope
    let home: URL
    let scannedAt: Date
    let duration: TimeInterval
    let signatures: SignatureStats
    let threats: [Threat]
}

enum ProtectSignatures {
    /// The bundled starter set merged with every signature file in `directory`.
    static func loadDatabase(signaturesDirectory directory: URL?,
                             fileSystem: any FileSystem = LocalFileSystem()) throws -> SignatureDatabase {
        var database = SignatureDatabase.bundledStarter()
        if let directory {
            try database.load(contentsOf: directory, fileSystem: fileSystem)
        }
        return database
    }

    /// Highest severity first, then by path; several threats per path stay together.
    static func sorted(_ threats: [Threat]) -> [Threat] {
        threats.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.path.path != rhs.path.path { return lhs.path.path < rhs.path.path }
            return lhs.name < rhs.name
        }
    }

    /// One threat per path (the first in severity order wins), for quarantine.
    static func uniquePaths(_ threats: [Threat]) -> [Threat] {
        var seen = Set<String>()
        return sorted(threats).filter { seen.insert($0.path.standardizedFileURL.path).inserted }
    }

    static func parseScope(_ argument: String) throws -> ScanScope {
        guard let scope = ScanScope(rawValue: argument.lowercased()) else {
            throw ValidationError("Unknown scope '\(argument)'. Expected one of: "
                                  + ScanScope.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return scope
    }
}

// MARK: - scan

struct ProtectScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for malware. Exits 3 when threats are found.")

    @Option(name: .long, help: "quick, normal (default) or deep.", transform: ProtectSignatures.parseScope)
    var scope: ScanScope = .normal

    @Option(name: .long, help: "Home directory to scan (default: the current user's home).")
    var home: String?

    @Option(name: .long, help: "Directory of extra .hdb/.hsb/.ndb/.ign2 signature files merged with the bundled set.")
    var signatures: String?

    @Flag(name: .long, help: "Print a JSON document instead of text; suppresses progress output.")
    var json = false

    func run() async throws {
        let database = try ProtectSignatures.loadDatabase(
            signaturesDirectory: signatures.map { fileURL(fromArgument: $0, isDirectory: true) })
        let context = ScanContext(fileSystem: LocalFileSystem(),
                                  home: home.map { fileURL(fromArgument: $0, isDirectory: true) })
        var options = ProtectScanOptions()
        options.scope = scope
        options.json = json
        let outcome = await ProtectScan.run(context: context, database: database, options: options, io: .standard)
        if let failure = outcome.failure {
            throw ValidationError("Scan failed: \(failure)")
        }
        if !outcome.document.threats.isEmpty {
            throw ExitCode(3)
        }
    }
}

struct ProtectScanOptions: Sendable {
    var scope: ScanScope = .normal
    var json = false
    var showProgress = true
}

struct ProtectScanOutcome: Sendable {
    let document: ThreatScanDocument
    /// Set when the scanner stream threw; the document holds what was found before that.
    let failure: String?
}

/// Testable core of `protect scan`.
enum ProtectScan {
    static func run(context: ScanContext, database: SignatureDatabase,
                    options: ProtectScanOptions, io: CommandIO) async -> ProtectScanOutcome {
        let progress = options.showProgress && !options.json
        let scanner = MalwareScanner(scope: options.scope, database: database)
        let stats = SignatureStats(database.stats)
        if progress {
            io.err.write("[started]  protection.malware: scope \(options.scope.rawValue), home \(context.home.path), signatures: \(stats.summary)")
        }
        let clock = ContinuousClock()
        let start = clock.now
        var threats: [Threat] = []
        var failure: String?
        do {
            for try await threat in scanner.scanThreats(context) {
                threats.append(threat)
                if progress {
                    io.err.write("[threat]   \(threat.severity.rawValue) \(threat.name): \(threat.path.path)")
                }
            }
        } catch {
            failure = String(describing: error)
            if progress { io.err.write("[failed]   protection.malware: \(failure ?? "")") }
        }
        let elapsed = clock.now - start
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if progress {
            io.err.write("[finished] protection.malware: \(threats.count) threat\(threats.count == 1 ? "" : "s"), \(String(format: "%.1f", duration)) s")
        }

        let document = ThreatScanDocument(scope: options.scope, home: context.home, scannedAt: context.now,
                                          duration: duration, signatures: stats,
                                          threats: ProtectSignatures.sorted(threats))
        if options.json {
            if let text = try? ScanJSON.encode(document) {
                io.out.write(text)
            } else {
                io.err.write("error: could not encode scan results as JSON")
            }
        } else {
            io.out.write(render(document))
        }
        return ProtectScanOutcome(document: document, failure: failure)
    }

    /// Threats grouped by severity, highest first.
    static func render(_ document: ThreatScanDocument) -> String {
        let meta = "scope \(document.scope.rawValue), \(String(format: "%.1f", document.duration)) s, signatures: \(document.signatures.summary)"
        guard !document.threats.isEmpty else {
            return "No threats found (\(meta))."
        }
        var lines = ["\(document.threats.count) threat\(document.threats.count == 1 ? "" : "s") found (\(meta)):"]
        for severity in ThreatSeverity.allCases.reversed() {
            let group = document.threats.filter { $0.severity == severity }
            guard !group.isEmpty else { continue }
            lines.append("")
            lines.append("\(severity.rawValue.uppercased()) (\(group.count))")
            let nameWidth = group.map { $0.name.count }.max() ?? 0
            let sizeWidth = group.map { ByteFormatter.string($0.sizeBytes).count }.max() ?? 0
            for threat in ProtectSignatures.sorted(group) {
                lines.append("  " + TableFormatter.padRight(threat.name, to: nameWidth)
                             + "  [\(threat.kind.rawValue)]  "
                             + TableFormatter.padLeft(ByteFormatter.string(threat.sizeBytes), to: sizeWidth)
                             + "  " + threat.path.path + (threat.isDirectory ? "/" : ""))
                lines.append("      " + threat.detail)
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - quarantine

struct ProtectQuarantineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quarantine",
        abstract: "Move the threats listed in a scan JSON document into a quarantine directory (chmod 000, manifest for restore).")

    @Option(name: .customLong("from-json"), help: "Document produced by `maccleaner protect scan --json`.")
    var fromJSON: String

    @Option(name: .long, help: "Quarantine directory (created if missing).")
    var dir: String

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var yes = false

    func run() async throws {
        let document = try ScanJSON.decode(ThreatScanDocument.self, from: fileURL(fromArgument: fromJSON, isDirectory: false))
        let directory = fileURL(fromArgument: dir, isDirectory: true)
        var options = ProtectQuarantineOptions()
        options.assumeYes = yes
        let outcome = await ProtectQuarantineRunner.run(threats: document.threats,
                                                        quarantine: ThreatQuarantine(directory: directory),
                                                        directory: directory, options: options,
                                                        confirm: { promptForConfirmation() }, io: .standard)
        if let manifest = outcome.manifest, manifest.records.contains(where: { !$0.succeeded }) {
            throw ExitCode(1)
        }
    }
}

struct ProtectQuarantineOptions: Sendable {
    var assumeYes = false
}

struct ProtectQuarantineOutcome: Sendable {
    let selected: [Threat]
    let manifest: QuarantineManifest?
    let manifestURL: URL?
    let aborted: Bool
}

/// Testable core of `protect quarantine`.
enum ProtectQuarantineRunner {
    static func manifestURL(for manifest: QuarantineManifest, in directory: URL) -> URL {
        directory.standardizedFileURL
            .appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            .appendingPathComponent(ThreatQuarantine.manifestFileName, isDirectory: false)
    }

    static func run(threats: [Threat], quarantine: ThreatQuarantine, directory: URL,
                    options: ProtectQuarantineOptions, confirm: @Sendable () -> Bool,
                    io: CommandIO) async -> ProtectQuarantineOutcome {
        let selected = ProtectSignatures.uniquePaths(threats)
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        io.out.write("Would quarantine \(selected.count) item\(selected.count == 1 ? "" : "s") (\(ByteFormatter.string(totalBytes))) into \(directory.standardizedFileURL.path):")
        let nameWidth = selected.map { $0.name.count }.max() ?? 0
        for threat in selected {
            io.out.write("  [\(threat.severity.rawValue)]  \(TableFormatter.padRight(threat.name, to: nameWidth))  \(threat.path.path)")
        }
        if selected.isEmpty {
            io.out.write("Nothing to quarantine.")
            return ProtectQuarantineOutcome(selected: selected, manifest: nil, manifestURL: nil, aborted: false)
        }
        if !options.assumeYes, !confirm() {
            io.out.write("Aborted.")
            return ProtectQuarantineOutcome(selected: selected, manifest: nil, manifestURL: nil, aborted: true)
        }

        let manifest = await quarantine.quarantine(selected)
        let url = manifestURL(for: manifest, in: directory)
        let succeeded = manifest.records.filter(\.succeeded).count
        for record in manifest.records where !record.succeeded {
            io.err.write("[failed]   \(record.threat.path.path): \(record.error ?? "unknown error")")
        }
        io.out.write("Quarantined \(succeeded) of \(manifest.records.count) item\(manifest.records.count == 1 ? "" : "s").")
        if succeeded < manifest.records.count {
            io.out.write("\(manifest.records.count - succeeded) item\(manifest.records.count - succeeded == 1 ? "" : "s") could not be quarantined; see stderr.")
        }
        io.out.write("Manifest written to \(url.path)")
        io.out.write("Restore with: maccleaner protect restore --manifest \(url.path) --dir \(directory.standardizedFileURL.path)")
        return ProtectQuarantineOutcome(selected: selected, manifest: manifest, manifestURL: url, aborted: false)
    }
}

// MARK: - restore

struct ProtectRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Move quarantined items back to their original paths.")

    @Option(name: .long, help: "manifest.json written by `maccleaner protect quarantine`.")
    var manifest: String

    @Option(name: .long, help: "The quarantine directory the manifest lives in.")
    var dir: String

    func run() async throws {
        let loaded = try ScanJSON.decode(QuarantineManifest.self, from: fileURL(fromArgument: manifest, isDirectory: false))
        let directory = fileURL(fromArgument: dir, isDirectory: true)
        let outcome = await ProtectRestoreRunner.run(manifest: loaded, quarantine: ThreatQuarantine(directory: directory),
                                                     io: .standard)
        if outcome.failed > 0 {
            throw ExitCode(1)
        }
    }
}

/// Testable core of `protect restore`.
enum ProtectRestoreRunner {
    struct Outcome: Sendable {
        let restored: Int
        let failed: Int
        let records: [QuarantineRecord]
    }

    static func run(manifest: QuarantineManifest, quarantine: ThreatQuarantine, io: CommandIO) async -> Outcome {
        let records = await quarantine.restore(manifest)
        let restored = records.filter { $0.succeeded && $0.storedAt == nil }.count
        let failed = records.count - restored
        for record in records where !record.succeeded || record.storedAt != nil {
            io.err.write("[failed]   \(record.threat.path.path): \(record.error ?? "was never quarantined")")
        }
        io.out.write("Restored \(restored) item\(restored == 1 ? "" : "s"), \(failed) failed.")
        return Outcome(restored: restored, failed: failed, records: records)
    }
}

// MARK: - update

struct ProtectUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Download the signature feed (manifest.json plus files) into a directory, verifying SHA-256.")

    @Option(name: .long, help: "Base URL of the feed, e.g. https://example.com/signatures/", transform: ProtectUpdateCommand.parseURL)
    var feed: URL

    @Option(name: .long, help: "Directory the signature files are written to. Files an earlier update installed that the feed no longer lists are removed from it.")
    var dest: String

    func run() async throws {
        let updater = SignatureUpdater(baseURL: feed, session: .shared,
                                       destination: fileURL(fromArgument: dest, isDirectory: true))
        do {
            _ = try await ProtectUpdateRunner.run(updater: updater, io: .standard)
        } catch {
            // The runner already reported the failure on stderr.
            throw ExitCode(1)
        }
    }

    static func parseURL(_ argument: String) throws -> URL {
        guard let url = URL(string: argument), url.scheme != nil else {
            throw ValidationError("'\(argument)' is not an absolute URL.")
        }
        return url
    }
}

/// Testable core of `protect update`.
enum ProtectUpdateRunner {
    static func run(updater: SignatureUpdater, io: CommandIO) async throws -> SignatureUpdateResult {
        let before = updater.currentVersion()
        io.err.write("[started]  signature update from \(updater.baseURL.absoluteString) (current: \(before ?? "none"))")
        let result: SignatureUpdateResult
        do {
            result = try await updater.update()
        } catch {
            io.err.write("[failed]   signature update: \(error.localizedDescription)")
            throw error
        }
        if result.filesUpdated == 0 {
            io.out.write("Signatures already at version \(result.version); nothing to download.")
        } else {
            io.out.write("Signatures updated to version \(result.version): \(result.filesUpdated) file\(result.filesUpdated == 1 ? "" : "s"), \(ByteFormatter.string(result.bytes)) downloaded into \(updater.destination.path)")
        }
        return result
    }
}

// MARK: - sigs

struct ProtectSigsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sigs",
        abstract: "Show how many signatures are loaded (bundled starter set plus --signatures).")

    @Option(name: .long, help: "Directory of extra .hdb/.hsb/.ndb/.ign2 signature files.")
    var signatures: String?

    @Flag(name: .long, help: "Print the statistics as JSON.")
    var json = false

    func run() async throws {
        let directory = signatures.map { fileURL(fromArgument: $0, isDirectory: true) }
        let database = try ProtectSignatures.loadDatabase(signaturesDirectory: directory)
        try ProtectSigs.run(database: database, directory: directory, json: json, io: .standard)
    }
}

/// Testable core of `protect sigs`.
enum ProtectSigs {
    static func render(_ stats: SignatureStats, directory: URL?) -> String {
        var lines = ["Signature sources: bundled starter set" + (directory.map { " + \($0.path)" } ?? "")]
        lines.append("  Hash signatures:    \(stats.hashSignatures)")
        lines.append("  Pattern signatures: \(stats.patternSignatures)")
        lines.append("  Allowlisted names:  \(stats.allowlisted)")
        lines.append("  Skipped lines:      \(stats.skippedLines)")
        return lines.joined(separator: "\n")
    }

    static func run(database: SignatureDatabase, directory: URL?, json: Bool, io: CommandIO) throws {
        let stats = SignatureStats(database.stats)
        if json {
            io.out.write(try ScanJSON.encode(stats))
        } else {
            io.out.write(render(stats, directory: directory))
        }
    }
}
