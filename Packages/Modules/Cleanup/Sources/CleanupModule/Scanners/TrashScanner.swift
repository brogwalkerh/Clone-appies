import Foundation
import CleanerCore

/// Every top-level item in the user's Trash, and on macOS in the per-user
/// `.Trashes/<uid>` folder of every mounted volume.
public struct TrashScanner: CleanerScanner {
    public static let id = "cleanup.trash"
    public let displayName = "Trash Bins"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            let detail = rules.rule(id: "trash")?.description
            var roots = [context.homePath(".Trash")]
            #if os(macOS)
            let uid = String(getuid())
            let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            for volume in context.readableChildren(of: volumes) {
                roots.append(volume.appendingPathComponent(".Trashes").appendingPathComponent(uid))
            }
            #endif
            for root in roots {
                if context.shouldSkip(root) { continue }
                for item in context.readableChildren(of: root) {
                    try Task.checkCancellation()
                    if item.lastPathComponent == ".DS_Store" { continue }
                    if let finding = await context.finding(at: item, category: CleanupCategory.trash,
                                                           scannerID: Self.id, risk: .safe, detail: detail) {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
