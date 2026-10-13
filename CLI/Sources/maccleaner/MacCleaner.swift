import ArgumentParser
import Foundation

/// Reported by `maccleaner --version`.
let maccleanerVersion = "0.1.0"

@main
struct MacCleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maccleaner",
        abstract: "Scan a macOS home directory for junk and remove it safely (Trash first, undo via manifests).",
        version: maccleanerVersion,
        subcommands: [ListScannersCommand.self, ScanCommand.self, RemoveCommand.self, UndoCommand.self,
                      MaintenanceCommand.self, LoginItemsCommand.self, ProtectCommand.self])
}
