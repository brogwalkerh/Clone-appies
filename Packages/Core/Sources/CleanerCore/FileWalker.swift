import Foundation

/// Recursive directory walker used by scanners.
///
/// Semantics:
/// - Iterative depth-first traversal (explicit stack), so arbitrarily deep
///   trees never overflow the call stack.
/// - The root itself is not yielded; its direct children are at depth 1.
///   `maxDepth: 1` yields only direct children, `nil` means unlimited.
/// - Symlinks are yielded but not followed unless `followsSymlinks` is true.
///   When following, a set of resolved directory paths guards against loops.
/// - Entries under a protected path are neither yielded nor descended into.
/// - Package (bundle) directories are yielded but not descended into when
///   `skipsPackageContents` is true.
/// - Unreadable directories are skipped silently; only an unreadable root
///   throws.
public struct FileWalker: Sendable {
    private let fileSystem: any FileSystem
    private let followsSymlinks: Bool
    private let skipsPackageContents: Bool
    private let protectedPaths: ProtectedPaths

    public init(fileSystem: any FileSystem, followsSymlinks: Bool = false, skipsPackageContents: Bool = true) {
        self.init(fileSystem: fileSystem, followsSymlinks: followsSymlinks,
                  skipsPackageContents: skipsPackageContents, protectedPaths: .default)
    }

    /// Additional initializer with an explicit protected-path set.
    public init(fileSystem: any FileSystem, followsSymlinks: Bool = false,
                skipsPackageContents: Bool = true, protectedPaths: ProtectedPaths) {
        self.fileSystem = fileSystem
        self.followsSymlinks = followsSymlinks
        self.skipsPackageContents = skipsPackageContents
        self.protectedPaths = protectedPaths
    }

    public func walk(_ root: URL, maxDepth: Int? = nil) -> AsyncThrowingStream<(URL, FileAttributes), any Error> {
        let (stream, continuation) = AsyncThrowingStream<(URL, FileAttributes), any Error>.makeStream()
        let walker = self
        let task = Task.detached(priority: .utility) {
            do {
                try walker.performWalk(root: root, maxDepth: maxDepth) { url, attributes in
                    continuation.yield((url, attributes))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func directorySize(_ root: URL) async throws -> Int64 {
        let rootAttributes = try fileSystem.attributes(of: root)
        if !rootAttributes.isDirectory {
            return rootAttributes.isSymlink ? 0 : rootAttributes.sizeBytes
        }
        var total: Int64 = 0
        for try await (_, attributes) in walk(root) {
            if !attributes.isDirectory && !attributes.isSymlink {
                total += attributes.sizeBytes
            }
        }
        return total
    }

    // MARK: - Implementation

    private struct Frame {
        let url: URL
        let depth: Int
    }

    private func performWalk(root: URL, maxDepth: Int?,
                             yield: (URL, FileAttributes) throws -> Void) throws {
        let root = root.standardizedFileURL
        if protectedPaths.isProtected(root) { return }
        let rootAttributes = try fileSystem.attributes(of: root)
        var visited = Set<String>()

        func descendable(_ url: URL, _ attributes: FileAttributes) -> URL? {
            if attributes.isDirectory {
                if attributes.isPackage && skipsPackageContents { return nil }
                return url
            }
            if attributes.isSymlink && followsSymlinks {
                let resolved = url.resolvingSymlinksInPath()
                guard let targetAttributes = try? fileSystem.attributes(of: resolved),
                      targetAttributes.isDirectory else { return nil }
                if targetAttributes.isPackage && skipsPackageContents { return nil }
                if protectedPaths.isProtected(resolved) { return nil }
                return resolved
            }
            return nil
        }

        guard let rootDirectory = descendable(root, rootAttributes) else { return }
        if let limit = maxDepth, limit < 1 { return }
        visited.insert(realKey(rootDirectory))

        var stack: [Frame] = [Frame(url: rootDirectory, depth: 0)]
        while let frame = stack.popLast() {
            if Task.isCancelled { return }
            guard let children = try? fileSystem.children(of: frame.url) else { continue }
            let childDepth = frame.depth + 1
            var pending: [Frame] = []
            for child in children {
                if Task.isCancelled { return }
                if protectedPaths.isProtected(child) { continue }
                guard let attributes = try? fileSystem.attributes(of: child) else { continue }
                try yield(child, attributes)
                if let limit = maxDepth, childDepth >= limit { continue }
                if let directory = descendable(child, attributes) {
                    let key = realKey(directory)
                    guard visited.insert(key).inserted else { continue }
                    pending.append(Frame(url: directory, depth: childDepth))
                }
            }
            // Push in reverse so children are visited in listing order.
            stack.append(contentsOf: pending.reversed())
        }
    }

    private func realKey(_ url: URL) -> String {
        if followsSymlinks {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.standardizedFileURL.path
    }
}
