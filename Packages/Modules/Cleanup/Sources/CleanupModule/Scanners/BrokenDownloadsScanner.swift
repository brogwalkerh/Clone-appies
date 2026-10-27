import Foundation
import CleanerCore

/// Partial downloads in `~/Downloads`, plus installer images and archives
/// older than 30 days as the `cleanup.oldInstallers` category.
public struct BrokenDownloadsScanner: CleanerScanner {
    public static let id = "cleanup.brokenDownloads"
    public static let oldInstallersCategoryID = "cleanup.oldInstallers"
    public static let installerAgeDays = 30

    public let displayName = "Broken Downloads"
    public let module = ModuleID.cleanup

    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "zip"]

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
                                                           scannerID: Self.id, risk: installerRule?.risk ?? .caution,
                                                           detail: "Downloaded \(days) days ago") {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
