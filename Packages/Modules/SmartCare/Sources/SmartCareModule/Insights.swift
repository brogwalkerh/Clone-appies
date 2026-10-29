import Foundation
import CleanerCore
import CleanupModule

public enum InsightSource: String, Codable, Sendable {
    case rules, onDeviceModel
}

/// "What is this, and is it safe to remove?" for one finding (Smart Insights, PLAN.md §3.2).
public struct Insight: Sendable, Hashable, Codable {
    public let title: String
    public let explanation: String
    public let advice: String
    public let source: InsightSource

    public init(title: String, explanation: String, advice: String, source: InsightSource) {
        self.title = title
        self.explanation = explanation
        self.advice = advice
        self.source = source
    }
}

public protocol InsightProvider: Sendable {
    func insight(for finding: Finding, home: URL) async -> Insight?
}

/// The offline fallback: the Cleanup rule that matched the path, else a
/// built-in sentence per category; advice follows the finding's risk.
public struct RuleTableInsightProvider: InsightProvider {
    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func insight(for finding: Finding, home: URL) async -> Insight? {
        guard let explanation = explanation(for: finding, home: home) else { return nil }
        return Insight(title: finding.category.displayName, explanation: explanation,
                       advice: Self.advice(for: finding), source: .rules)
    }

    /// The rule text for the path, if a Cleanup rule covers it.
    public func ruleText(for finding: Finding, home: URL) -> String? {
        rules.description(forPath: finding.path, home: home)
    }

    func explanation(for finding: Finding, home: URL) -> String? {
        if let text = ruleText(for: finding, home: home) { return text }
        if let text = Self.categoryTable[finding.category.id] { return text }
        if finding.category.id.hasPrefix("privacy.") {
            return "Browsing or app activity data that reveals what you did on this Mac."
        }
        return finding.detail
    }

    /// Advice from the finding's module and risk; the on-device provider reuses it.
    public static func advice(for finding: Finding) -> String {
        switch finding.category.module {
        case .clutter:
            return "These are your own files. Remove them only if you no longer need them; they go to the Trash first."
        case .protection where finding.category.id == "protection.malware":
            return "Quarantine it: the file is locked away and can be restored if this is a false alarm."
        default:
            break
        }
        switch finding.risk {
        case .safe:
            return "Safe to remove. Nothing you made is lost, and apps recreate what they need."
        case .caution:
            return "Usually safe to remove, but an app may ask you to sign in again or rebuild its data."
        case .risky:
            return "Review before removing: this can lose data or stop an app from working."
        }
    }

    /// Categories whose findings no Cleanup rule describes.
    static let categoryTable: [String: String] = [
        "cleanup.userCaches": "Temporary files apps keep to start and load faster. Apps rebuild them as needed.",
        "cleanup.logs": "Diagnostic text that apps and macOS write while running. Only useful when troubleshooting.",
        "cleanup.crashReports": "Reports written when an app crashed. Developers use them; you rarely need them.",
        "cleanup.trash": "Items you already moved to the Trash. Emptying it deletes them for good and frees their space.",
        "cleanup.brokenDownloads": "Downloads that never finished. They cannot be opened and can be downloaded again.",
        "cleanup.purgeable": "Space macOS can reclaim on its own, mostly local snapshots and cached iCloud files.",
        "clutter.largeFiles": "A large file you have not opened in a long time.",
        "clutter.oldFiles": "A file you have not opened in a long time.",
        "clutter.duplicates": "An exact copy of another file on this Mac. The other copy is kept.",
        "clutter.similarImages": "A photo that looks almost the same as another one. The best-looking copy is kept.",
        "clutter.downloads": "Something in your Downloads folder, such as an installer, archive or screenshot.",
        "applications.leftovers": "Support files of an app you are uninstalling: caches, settings and saved data.",
        "applications.orphaned": "Files left behind by an app that is no longer installed.",
        "applications.installers": "A disk image or installer package. The app it installed keeps working without it.",
        "performance.brokenLoginItems": "A launch item that points to a program that no longer exists. It does nothing but fail at login.",
        "protection.malware": "A file that matches a known malware signature or a suspicious pattern.",
    ]
}

/// Asks `primary` (the on-device model) and falls back when it has no answer.
public struct FallbackInsightProvider: InsightProvider {
    private let primary: any InsightProvider
    private let fallback: any InsightProvider

    public init(primary: any InsightProvider, fallback: any InsightProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func insight(for finding: Finding, home: URL) async -> Insight? {
        if let answer = await primary.insight(for: finding, home: home) { return answer }
        return await fallback.insight(for: finding, home: home)
    }
}

/// Text for the on-device model. Only facts we know go in, so the model
/// explains rather than invents; the risk rating is ours, not the model's.
public enum InsightPrompt {
    public static let instructions = """
        You explain files and folders on a Mac to its owner before they delete them. \
        Answer in at most two short sentences: what the item is, and what happens if it is removed. \
        Use only the facts given. If you are not sure what the item is, say so. Do not give commands.
        """

    public static func make(for finding: Finding, home: URL, ruleText: String?) -> String {
        var lines = [
            "Item: \(displayPath(finding.path, home: home))",
            "Kind: \(finding.isDirectory ? "folder" : "file")",
            "Size: \(ByteFormatter.string(finding.sizeBytes))",
            "Last modified: \(finding.modifiedAt.map(isoDay) ?? "unknown")",
            "Category: \(finding.category.displayName)",
            "Risk rating: \(finding.risk.rawValue)",
        ]
        if let ruleText { lines.append("Known description: \(ruleText)") }
        if let detail = finding.detail, detail != ruleText { lines.append("Scanner note: \(detail)") }
        return lines.joined(separator: "\n")
    }

    /// `~/…` under home; the full path elsewhere.
    static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
