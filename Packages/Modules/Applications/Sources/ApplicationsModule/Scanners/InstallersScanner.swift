import Foundation
import CleanerCore

/// Disk images and installer packages lying around in Downloads, Desktop and
/// Documents (top level only).
///
/// Only items in `~/Downloads` are `.caution`. A `.dmg` or `.pkg` the user
/// filed under Desktop or Documents was put there on purpose (an encrypted
/// vault image, an archived installer), so those are review-only (`.risky`).
/// `.iso` images are not app installers and are not reported.
public struct InstallersScanner: CleanerScanner {
    public static let id = "applications.installers"
    public let displayName = "Installers"
    public let module = ModuleID.applications

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg"]
    static let roots = ["Downloads", "Desktop", "Documents"]
    /// The one root whose findings may be pre-selected.
    static let downloadsRoot = "Downloads"

    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            for root in Self.roots {
                try Task.checkCancellation()
                let inDownloads = root == Self.downloadsRoot
                let risk: RiskLevel = inDownloads ? .caution : .risky
                let label = inDownloads ? "Installer" : "Disk image or installer package"
                for item in context.readableChildren(of: context.homePath(root)) {
                    try Task.checkCancellation()
                    guard Self.extensions.contains(item.pathExtension.lowercased()) else { continue }
                    guard let attributes = try? context.fileSystem.attributes(of: item),
                          !attributes.isSymlink else { continue }
                    let detail: String
                    if let modified = attributes.modifiedAt {
                        let days = max(0, Int(context.now.timeIntervalSince(modified) / 86_400))
                        detail = "\(label), modified \(days) days ago"
                    } else {
                        detail = label
                    }
                    if let finding = await context.finding(at: item, category: ApplicationsCategory.installers,
                                                           scannerID: Self.id, risk: risk, detail: detail) {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
