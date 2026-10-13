import Foundation
import CleanerCore

/// Downloads triage: top-level items in `~/Downloads` that are installers,
/// screenshots / screen recordings, or stale. Each item is reported once with
/// the first matching rule's detail; folders are sized recursively.
public struct DownloadsScanner: CleanerScanner {
    public static let id = "clutter.downloads"
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "mpkg"]
    public static let screenshotPrefixes = ["Screenshot", "Screen Recording"]
    /// In-progress downloads belong to the Cleanup module's Broken Downloads.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial"]

    public let displayName = "Downloads"
    public let module = ModuleID.clutter

    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 90 * 86_400) {
        self.staleAfter = staleAfter
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let staleAfter = self.staleAfter
        return makeFindingStream { emitter in
            let downloads = context.homePath("Downloads")
            for item in context.readableChildren(of: downloads) {
                try Task.checkCancellation()
                let item = item.standardizedFileURL
                if context.shouldSkip(item) { continue }
                let name = item.lastPathComponent
                if name.hasPrefix(".") || Self.partialExtensions.contains(item.pathExtension.lowercased()) { continue }
                guard let attributes = try? context.fileSystem.attributes(of: item), !attributes.isSymlink else { continue }
                guard let detail = Self.detail(for: item, attributes: attributes, now: context.now,
                                               staleAfter: staleAfter) else { continue }
                if let finding = await context.finding(at: item, category: ClutterCategory.downloads,
                                                       scannerID: Self.id, risk: .caution, detail: detail) {
                    emitter.emit(finding)
                }
            }
        }
    }

    /// Detail for the first matching rule, in precedence order: installer,
    /// screenshot, stale. nil when no rule matches.
    static func detail(for url: URL, attributes: FileAttributes, now: Date, staleAfter: TimeInterval) -> String? {
        if installerExtensions.contains(url.pathExtension.lowercased()) {
            return "Installer"
        }
        let name = url.lastPathComponent.lowercased()
        if screenshotPrefixes.contains(where: { name.hasPrefix($0.lowercased()) }) {
            return "Screenshot"
        }
        if let modified = attributes.modifiedAt {
            let age = now.timeIntervalSince(modified)
            if age >= staleAfter {
                return "Downloaded \(Int(age / 86_400)) days ago"
            }
        }
        return nil
    }
}
