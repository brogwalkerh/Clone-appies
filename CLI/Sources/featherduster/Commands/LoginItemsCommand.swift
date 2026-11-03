import ArgumentParser
import Foundation
import CleanerCore
import PerformanceModule

struct LoginItemsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-items",
        abstract: "Inspect login and background items (launchd agents, daemons, helper tools).",
        subcommands: [LoginItemsListCommand.self])
}

struct LoginItemsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List login and background items grouped by domain.")

    @Flag(name: .long, help: "Print the items as a JSON array.")
    var json = false

    @Flag(name: .long, help: "Only show items whose program no longer exists.")
    var brokenOnly = false

    @Option(name: .long, help: "Home directory whose Library/LaunchAgents to read (default: the current user's home).")
    var home: String?

    func run() async throws {
        let homeURL = home.map { fileURL(fromArgument: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        var options = LoginItemsOptions()
        options.json = json
        options.brokenOnly = brokenOnly
        _ = try await LoginItemsList.run(inventory: BackgroundItemsInventory(fileSystem: LocalFileSystem()),
                                         home: homeURL, options: options, io: .standard)
    }
}

struct LoginItemsOptions: Sendable {
    var json = false
    var brokenOnly = false
}

/// Testable core of `login-items list`.
enum LoginItemsList {
    static func filter(_ items: [BackgroundItem], brokenOnly: Bool) -> [BackgroundItem] {
        brokenOnly ? items.filter(\.isBroken) : items
    }

    static func badges(_ item: BackgroundItem) -> [String] {
        var badges: [String] = []
        if item.isBroken { badges.append("broken") }
        if item.isApple { badges.append("apple") }
        if item.runAtLoad { badges.append("runAtLoad") }
        if item.keepAlive { badges.append("keepAlive") }
        if let enabled = item.enabledState { badges.append(enabled ? "enabled" : "disabled") }
        return badges
    }

    static func title(for domain: BackgroundItemDomain) -> String {
        switch domain {
        case .userAgent: return "User agents (~/Library/LaunchAgents)"
        case .systemAgent: return "System agents (/Library/LaunchAgents)"
        case .systemDaemon: return "System daemons (/Library/LaunchDaemons, /Library/PrivilegedHelperTools)"
        case .loginItemApp: return "Login item apps"
        }
    }

    static func render(_ items: [BackgroundItem]) -> String {
        guard !items.isEmpty else { return "No login or background items found." }
        var lines: [String] = []
        for domain in BackgroundItemDomain.allCases {
            let group = items.filter { $0.domain == domain }
            guard !group.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append("\(title(for: domain)) — \(group.count)")
            let labelWidth = group.map { $0.label.count }.max() ?? 0
            for item in group {
                let badges = badges(item)
                let badgeText = badges.isEmpty ? "" : "[" + badges.joined(separator: ", ") + "]"
                var line = "  " + TableFormatter.padRight(item.label, to: labelWidth) + "  "
                if !badgeText.isEmpty { line += badgeText + "  " }
                line += "-> " + (item.program ?? "(no program)")
                lines.append(line)
            }
        }
        let broken = items.filter(\.isBroken).count
        lines.append("")
        lines.append("\(items.count) item\(items.count == 1 ? "" : "s"), \(broken) broken.")
        return lines.joined(separator: "\n")
    }

    static func run(inventory: BackgroundItemsInventory, home: URL, options: LoginItemsOptions,
                    io: CommandIO) async throws -> [BackgroundItem] {
        let items = filter(try await inventory.discover(home: home), brokenOnly: options.brokenOnly)
        if options.json {
            io.out.write(try ScanJSON.encode(items))
        } else {
            io.out.write(render(items))
        }
        return items
    }
}
