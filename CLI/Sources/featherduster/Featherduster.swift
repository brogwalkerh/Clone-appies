import ArgumentParser
import Foundation

/// Reported by `featherduster --version`.
let featherdusterVersion = "0.1.0"

@main
struct Featherduster: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "featherduster",
        abstract: "Scan a macOS home directory for junk and remove it safely (Trash first, undo via manifests).",
        version: featherdusterVersion,
        subcommands: [ListScannersCommand.self, ScanCommand.self, RemoveCommand.self, UndoCommand.self,
                      MaintenanceCommand.self, LoginItemsCommand.self, ProtectCommand.self,
                      SmartCareCommand.self, ActionsCommand.self, ActivityCommand.self])
}
