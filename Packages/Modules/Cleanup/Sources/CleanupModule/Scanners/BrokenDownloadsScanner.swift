import Foundation
import CleanerCore

/// Partial downloads in `~/Downloads` that have been idle for at least
/// `partialIdleHours` (a younger one may still be downloading), plus disk
/// images and installer packages not modified for 30 days as the review-only
/// `cleanup.oldInstallers` category. Archives (`.zip`) are not installers:
/// they routinely hold the user's own documents.
public struct BrokenDownloadsScanner: CleanerScanner {
    public static let id = "cleanup.brokenDownloads"
    public static let oldInstallersCategoryID = "cleanup.oldInstallers"
    public static let installerAgeDays = 30
    /// A partial download is only offered once nothing in it has been written
    /// for this long; anything younger may be a live download.
    public static let partialIdleHours = 24

    public let displayName = "Broken Downloads"
    public let module = ModuleID.cleanup

    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial"]
    static let installerExtensions: Set<String> = ["dmg", "pkg"]

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            let downloads = context.homePath("Downloads")
            let partialRule = rules.rule(id: "brokenDownloads")
            let installerRule = rules.rule(id: "oldInstallers")
            let threshold = TimeInterval(Self.installerAgeDays) * 86_400

            for item in context.readableChildren(of: downloads) {
                try Task.checkCancellation()
                let ext = item.pathExtension.lowercased()
                if Self.partialExtensions.contains(ext) {
                    guard let lastWrite = await Self.newestModification(of: item, context: context),
                          context.now.timeIntervalSince(lastWrite) >= TimeInterval(Self.partialIdleHours) * 3_600
                    else { continue }
                    if let finding = await context.finding(at: item, category: CleanupCategory.brokenDownloads,
                                                           scannerID: Self.id, risk: partialRule?.risk ?? .safe,
                                                           detail: partialRule?.description) {
                        emitter.emit(finding)
                    }
                } else if Self.installerExtensions.contains(ext) {
                    guard let attributes = try? context.fileSystem.attributes(of: item),
                          let modified = attributes.modifiedAt else { continue }
                    let age = context.now.timeIntervalSince(modified)
                    guard age >= threshold else { continue }
                    let days = Int(age / 86_400)
                    if let finding = await context.finding(at: item, category: CleanupCategory.oldInstallers,
                                                           scannerID: Self.id, risk: installerRule?.risk ?? .risky,
                                                           detail: "Modified \(days) days ago") {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }

    /// Newest modification date of `item` and, for a directory (Safari's
    /// `.download` bundle), of everything inside it. nil when no date is
    /// known, in which case the item is not offered.
    static func newestModification(of item: URL, context: ScanContext) async -> Date? {
        guard let attributes = try? context.fileSystem.attributes(of: item) else { return nil }
        var newest = attributes.modifiedAt
        guard attributes.isDirectory else { return newest }
        do {
            for try await (_, child) in context.sizingWalker.walk(item) {
                if let modified = child.modifiedAt, modified > (newest ?? .distantPast) {
                    newest = modified
                }
            }
        } catch {
            return nil
        }
        return newest
    }
}
