import ArgumentParser
import Foundation
import CleanerCore
import SmartCareModule

struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore the items listed in a removal manifest from the Trash.",
        discussion: "Exits with status 1 when any item could not be restored.")

    @Option(name: .long, help: "Manifest written by `featherduster remove`.")
    var manifest: String

    @OptionGroup var history: HistoryOptions

    func run() async throws {
        let loaded = try ScanJSON.decode(RemovalManifest.self,
                                         from: fileURL(fromArgument: manifest, isDirectory: false))
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        let outcome = try await UndoRunner.run(manifest: loaded, remover: remover, activity: history.activity,
                                               io: .standard)
        if outcome.failed > 0 { throw ExitCode(1) }
    }
}

/// Testable core of `undo`.
enum UndoRunner {
    struct Outcome: Hashable, Sendable {
        let restored: Int
        let failed: Int
        let records: [RemovalRecord]
    }

    /// One `.undo` event per module with restored items, so My Activity
    /// subtracts what a recorded removal had counted as reclaimed.
    static func activityEvents(_ records: [RemovalRecord], date: Date = .now) -> [ActivityEvent] {
        let restored = records.filter(\.succeeded)
        return ModuleID.allCases.compactMap { module in
            let ofModule = restored.filter { $0.finding.category.module == module }
            return ofModule.isEmpty ? nil : ActivityEvent.undo(ofModule, module: module, date: date)
        }
    }

    static func run(manifest: RemovalManifest, remover: any Remover, activity: (any ActivityStore)? = nil,
                    io: CommandIO) async throws -> Outcome {
        let records = try await remover.undo(manifest)
        await record(activityEvents(records), in: activity, io: io)
        let restored = records.filter(\.succeeded).count
        let failed = records.count - restored
        for record in records where !record.succeeded {
            io.err.write("[failed]   \(record.finding.path.path): \(record.error ?? "unknown error")")
        }
        io.out.write("Restored \(restored) item\(restored == 1 ? "" : "s"), \(failed) failed.")
        return Outcome(restored: restored, failed: failed, records: records)
    }
}
