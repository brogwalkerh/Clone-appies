import Foundation
import CleanerCore

/// Categories shared by the Cleanup scanners.
enum CleanupCategory {
    static let userCaches = FindingCategory(id: "cleanup.userCaches", displayName: "User Cache Files", module: .cleanup)
    static let logs = FindingCategory(id: "cleanup.logs", displayName: "Log Files", module: .cleanup)
    static let crashReports = FindingCategory(id: "cleanup.crashReports", displayName: "Crash Reports", module: .cleanup)
    static let xcode = FindingCategory(id: "cleanup.xcode", displayName: "Xcode Junk", module: .cleanup)
    static let trash = FindingCategory(id: "cleanup.trash", displayName: "Trash Bins", module: .cleanup)
    static let brokenDownloads = FindingCategory(id: "cleanup.brokenDownloads", displayName: "Broken Downloads", module: .cleanup)
    static let oldInstallers = FindingCategory(id: "cleanup.oldInstallers", displayName: "Old Installers", module: .cleanup)
    static let aiLeftovers = FindingCategory(id: "cleanup.aiLeftovers", displayName: "AI Tool Leftovers", module: .cleanup)
    static let devCaches = FindingCategory(id: "cleanup.devCaches", displayName: "Developer Tool Caches", module: .cleanup)
    static let purgeable = FindingCategory(id: "cleanup.purgeable", displayName: "Purgeable Space", module: .cleanup)
}

/// Hands findings from a scanner body to its stream.
struct FindingEmitter: Sendable {
    let continuation: AsyncThrowingStream<Finding, any Error>.Continuation

    func emit(_ finding: Finding) {
        continuation.yield(finding)
    }
}

/// Runs `body` on a detached task and bridges it to an `AsyncThrowingStream`.
/// Cancelling the stream cancels the body.
func makeFindingStream(
    _ body: @escaping @Sendable (FindingEmitter) async throws -> Void
) -> AsyncThrowingStream<Finding, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Finding, any Error>.makeStream()
    let task = Task.detached(priority: .utility) {
        do {
            try await body(FindingEmitter(continuation: continuation))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}

extension ScanContext {
    /// True when the coordinator would drop `url` anyway: skip it early.
    func shouldSkip(_ url: URL) -> Bool {
        ignoreList.contains(url) || protectedPaths.isProtected(url)
    }

    /// Walker for size computation. Package contents are included so that
    /// `.app`, `.xcarchive` and `.download` bundles are sized correctly.
    var sizingWalker: FileWalker {
        FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                   skipsPackageContents: false, protectedPaths: protectedPaths)
    }

    /// Walker for listing. Package bundles are yielded but not entered.
    var listingWalker: FileWalker {
        FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                   skipsPackageContents: true, protectedPaths: protectedPaths)
    }

    func homePath(_ relative: String) -> URL {
        home.appendingPathComponent(relative).standardizedFileURL
    }

    /// Children of `url`, or `[]` when it is missing or unreadable.
    func readableChildren(of url: URL) -> [URL] {
        guard fileSystem.exists(url) else { return [] }
        return (try? fileSystem.children(of: url)) ?? []
    }

    /// Builds a finding for `url`, sizing directories recursively. Returns nil
    /// when the item is missing, unreadable, ignored or protected.
    func finding(at url: URL, category: FindingCategory, scannerID: String,
                 risk: RiskLevel, detail: String?) async -> Finding? {
        let url = url.standardizedFileURL
        if shouldSkip(url) { return nil }
        guard let attributes = try? fileSystem.attributes(of: url) else { return nil }
        let size: Int64
        if attributes.isDirectory {
            guard let total = try? await sizingWalker.directorySize(url) else { return nil }
            size = total
        } else if attributes.isSymlink {
            size = 0
        } else {
            size = attributes.sizeBytes
        }
        return Finding(path: url, sizeBytes: size, category: category, scannerID: scannerID,
                       risk: risk, detail: detail, modifiedAt: attributes.modifiedAt,
                       isDirectory: attributes.isDirectory)
    }

    /// Emits one finding per existing location named by the rules in
    /// `ruleCategory`, using each rule's risk and description.
    func emitRulePaths(ruleCategory: String, category: FindingCategory, scannerID: String,
                       rules: CleanupRules, emitter: FindingEmitter) async throws {
        for rule in rules.rules(inCategory: ruleCategory) {
            for relative in rule.relativePaths {
                for url in rules.expand(relative, home: home, fileSystem: fileSystem) {
                    try Task.checkCancellation()
                    if let finding = await finding(at: url, category: category, scannerID: scannerID,
                                                   risk: rule.risk, detail: rule.description) {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
