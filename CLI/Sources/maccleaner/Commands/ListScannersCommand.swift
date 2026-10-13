import ArgumentParser
import Foundation
import CleanerCore

struct ListScannersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-scanners",
        abstract: "List every registered scanner with its id, display name and module.")

    @Flag(help: "Print the list as a JSON array.")
    var json = false

    func run() async throws {
        try ListScanners.run(registry: .builtIn(), json: json, io: .standard)
    }
}

/// Testable core of `list-scanners`.
enum ListScanners {
    struct Entry: Codable, Hashable, Sendable {
        let id: String
        let displayName: String
        let module: ModuleID
    }

    static func entries(_ registry: ScannerRegistry) -> [Entry] {
        registry.scanners.map { Entry(id: $0.id, displayName: $0.displayName, module: $0.module) }
    }

    static func render(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "No scanners registered." }
        let idWidth = max(2, entries.map { $0.id.count }.max() ?? 0)
        let nameWidth = max(4, entries.map { $0.displayName.count }.max() ?? 0)
        var lines: [String] = []
        lines.append(TableFormatter.padRight("ID", to: idWidth) + "  "
                     + TableFormatter.padRight("Name", to: nameWidth) + "  Module")
        lines.append(String(repeating: "-", count: idWidth + 2 + nameWidth + 2 + 12))
        for entry in entries {
            lines.append(TableFormatter.padRight(entry.id, to: idWidth) + "  "
                         + TableFormatter.padRight(entry.displayName, to: nameWidth) + "  "
                         + entry.module.rawValue)
        }
        return lines.joined(separator: "\n")
    }

    static func run(registry: ScannerRegistry, json: Bool, io: CommandIO) throws {
        let list = entries(registry)
        if json {
            io.out.write(try ScanJSON.encode(list))
        } else {
            io.out.write(render(list))
        }
    }
}
