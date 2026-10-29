import ArgumentParser
import Foundation
import SmartCareModule

/// Where commands read and write My Activity history and My Tools action sets
/// (the same files the app uses, ADR 0007).
struct HistoryOptions: ParsableArguments {
    @Option(name: .customLong("data-dir"),
            help: "App data directory (default: ~/Library/Application Support/com.example.maccleaner).")
    var dataDir: String?

    @Flag(name: .customLong("no-history"), help: "Do not record this run in My Activity.")
    var noHistory = false

    var storage: SmartCareStorage {
        SmartCareStorage(directory: dataDir.map { fileURL(fromArgument: $0, isDirectory: true) }
                         ?? SmartCareStorage.defaultDirectory())
    }

    /// The activity log to record into, or nil with `--no-history`.
    var activity: (any ActivityStore)? {
        noHistory ? nil : storage.activity
    }
}

/// Appends events, reporting (not failing on) a write error: history is a convenience.
func record(_ events: [ActivityEvent], in store: (any ActivityStore)?, io: CommandIO) async {
    guard let store, !events.isEmpty else { return }
    do {
        try await store.append(events)
    } catch {
        io.err.write("warning: could not record activity: \(error)")
    }
}
