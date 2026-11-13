import Foundation
import CleanerCore

/// Launchd plists whose program is confirmed missing (see
/// `BackgroundItem.isBroken`). Each broken item's plist is emitted as a
/// finding so it can be trashed, always at `.risky`: "missing" is inferred
/// from a snapshot of the disk, and trashing the plist of an agent that still
/// works breaks it, so nothing may pre-select these (Smart Care, action sets
/// and `featherduster remove` all leave risky findings alone by default).
public struct BrokenLoginItemsScanner: CleanerScanner {
    public static let id = "performance.brokenLoginItems"
    public let displayName = "Broken Login Items"
    public let module = ModuleID.performance

    private let enabledStateProvider: (any LaunchdStateProvider)?

    public init() {
        self.init(enabledStateProvider: nil)
    }

    public init(enabledStateProvider: (any LaunchdStateProvider)?) {
        self.enabledStateProvider = enabledStateProvider
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let provider = enabledStateProvider
        return makeFindingStream { emitter in
            let inventory = BackgroundItemsInventory(fileSystem: context.fileSystem, enabledStateProvider: provider)
            let items = try await inventory.discover(home: context.home)
            for item in items where item.isBroken && !item.isApple {
                try Task.checkCancellation()
                let url = item.plistURL
                if context.shouldSkip(url) { continue }
                guard let attributes = try? context.fileSystem.attributes(of: url),
                      !attributes.isDirectory, !attributes.isSymlink else { continue }
                let program = item.program ?? "unknown program"
                emitter.emit(Finding(path: url, sizeBytes: attributes.sizeBytes,
                                     category: PerformanceCategory.brokenLoginItems,
                                     scannerID: Self.id, risk: .risky,
                                     detail: "\(item.label) points to a missing program: \(program)",
                                     modifiedAt: attributes.modifiedAt, isDirectory: false))
            }
        }
    }
}
