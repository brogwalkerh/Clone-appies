import ArgumentParser
import Foundation
import CleanerCore

struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore the items listed in a removal manifest from the Trash.")

    @Option(name: .long, help: "Manifest written by `maccleaner remove`.")
    var manifest: String

    func run() async throws {
        let loaded = try ScanJSON.decode(RemovalManifest.self,
                                         from: fileURL(fromArgument: manifest, isDirectory: false))
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        _ = try await UndoRunner.run(manifest: loaded, remover: remover, io: .standard)
    }
}

/// Testable core of `undo`.
enum UndoRunner {
    struct Outcome: Hashable, Sendable {
        let restored: Int
        let failed: Int
        let records: [RemovalRecord]
    }

    static func run(manifest: RemovalManifest, remover: any Remover, io: CommandIO) async throws -> Outcome {
        let records = try await remover.undo(manifest)
        let restored = records.filter(\.succeeded).count
        let failed = records.count - restored
        for record in records where !record.succeeded {
            io.err.write("[failed]   \(record.finding.path.path): \(record.error ?? "unknown error")")
        }
        io.out.write("Restored \(restored) item\(restored == 1 ? "" : "s"), \(failed) failed.")
        return Outcome(restored: restored, failed: failed, records: records)
    }
}
