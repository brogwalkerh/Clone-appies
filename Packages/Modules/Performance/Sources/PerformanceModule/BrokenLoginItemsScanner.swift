import Foundation
import CleanerCore

/// Launchd plists whose program no longer exists on disk. Each broken item's
/// plist is emitted as a finding so it can be trashed.
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
            for item in items where item.isBroken {
                try Task.checkCancellation()
                let url = item.plistURL
                if context.shouldSkip(url) { continue }
                guard let attributes = try? context.fileSystem.attributes(of: url),
                      !attributes.isDirectory, !attributes.isSymlink else { continue }
                let program = item.program ?? "unknown program"
                emitter.emit(Finding(path: url, sizeBytes: attributes.sizeBytes,
                                     category: PerformanceCategory.brokenLoginItems,
                                     scannerID: Self.id, risk: .safe,
                                     detail: "\(item.label) points to a missing program: \(program)",
                                     modifiedAt: attributes.modifiedAt, isDirectory: false))
            }
        }
    }
}
