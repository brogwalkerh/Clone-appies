import Foundation
import CleanerCore

/// Categories shared by the Applications module.
enum ApplicationsCategory {
    static let leftovers = FindingCategory(id: "applications.leftovers", displayName: "App Leftovers", module: .applications)
    static let orphaned = FindingCategory(id: "applications.orphaned", displayName: "Orphaned Leftovers", module: .applications)
    static let installers = FindingCategory(id: "applications.installers", displayName: "Installers", module: .applications)
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
    /// `.app` and `.pkg` bundles are sized correctly.
    var sizingWalker: FileWalker {
        FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                   skipsPackageContents: false, protectedPaths: protectedPaths)
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
}

extension FileSystem {
    /// Children of `url`, or `[]` when it is missing or unreadable.
    func readableChildren(of url: URL) -> [URL] {
        guard exists(url) else { return [] }
        return (try? children(of: url)) ?? []
    }
}
