import Foundation
import CleanerCore

/// Disk images and installer packages lying around in Downloads, Desktop and
/// Documents (top level only).
public struct InstallersScanner: CleanerScanner {
    public static let id = "applications.installers"
    public let displayName = "Installers"
    public let module = ModuleID.applications

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
    static let roots = ["Downloads", "Desktop", "Documents"]

    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            for root in Self.roots {
                try Task.checkCancellation()
                for item in context.readableChildren(of: context.homePath(root)) {
                    try Task.checkCancellation()
                    guard Self.extensions.contains(item.pathExtension.lowercased()) else { continue }
                    guard let attributes = try? context.fileSystem.attributes(of: item),
                          !attributes.isSymlink else { continue }
                    let detail: String
                    if let modified = attributes.modifiedAt {
                        let days = max(0, Int(context.now.timeIntervalSince(modified) / 86_400))
                        detail = "Installer, \(days) days old"
                    } else {
                        detail = "Installer"
                    }
                    if let finding = await context.finding(at: item, category: ApplicationsCategory.installers,
                                                           scannerID: Self.id, risk: .caution, detail: detail) {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
