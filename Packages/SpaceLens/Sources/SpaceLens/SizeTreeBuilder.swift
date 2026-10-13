import CleanerCore
import Foundation

/// Builds a `SizeNode` tree by walking the filesystem through an injected
/// `FileSystem` (never `FileManager` directly), so it can be tested against fixtures.
///
/// Semantics:
/// - `root` is depth 0; entries at depth `maxDepth` are included as nodes but
///   their `children` are empty. Directories deeper than `maxDepth` are still
///   walked for their total size, so every directory's `sizeBytes` is its full
///   recursive size regardless of `maxDepth`.
/// - Symlinks are never followed: they appear as leaves with the size the
///   `FileSystem` reports for the link itself.
/// - Entries whose attributes or listing cannot be read (e.g. permission denied)
///   are skipped; an unreadable directory still appears with size 0 and no
///   children. Only a failure to read `root` itself throws.
/// - Top-level children are walked concurrently with a bounded `TaskGroup`.
///   The result is `sorted()` (size descending), so output is deterministic.
public struct SizeTreeBuilder: Sendable {
    public let fileSystem: any FileSystem

    /// Upper bound on concurrently walked top-level children.
    let maxConcurrency: Int

    public init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, maxConcurrency: max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)))
    }

    init(fileSystem: any FileSystem, maxConcurrency: Int) {
        self.fileSystem = fileSystem
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func build(root: URL, maxDepth: Int = 3) async throws -> SizeNode {
        let root = root.standardizedFileURL
        let attributes = try fileSystem.attributes(of: root)
        let maxDepth = max(0, maxDepth)

        guard attributes.isDirectory, !attributes.isSymlink else {
            return SizeNode(id: root, name: Self.displayName(for: root), sizeBytes: max(0, attributes.sizeBytes),
                            isDirectory: false)
        }

        let entries = try fileSystem.children(of: root).sorted { $0.path < $1.path }
        let includeChildren = maxDepth >= 1

        var children: [SizeNode] = []
        children.reserveCapacity(entries.count)

        try await withThrowingTaskGroup(of: (Int, SizeNode?).self) { group in
            var nextIndex = 0
            var results = [SizeNode?](repeating: nil, count: entries.count)

            func enqueue() {
                guard nextIndex < entries.count else { return }
                let index = nextIndex
                let url = entries[index]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, self.walk(url, depth: 1, maxDepth: maxDepth))
                }
            }

            for _ in 0..<min(maxConcurrency, entries.count) { enqueue() }
            while let (index, node) = try await group.next() {
                results[index] = node
                enqueue()
            }
            children = results.compactMap { $0 }
        }

        let total = children.reduce(Int64(0)) { $0 &+ $1.sizeBytes }
        return SizeNode(id: root, name: Self.displayName(for: root), sizeBytes: total, isDirectory: true,
                        children: includeChildren ? children : []).sorted()
    }

    // MARK: - Synchronous walk

    /// Returns the node for `url` at `depth`, or `nil` if it must be skipped.
    private func walk(_ url: URL, depth: Int, maxDepth: Int) -> SizeNode? {
        guard let attributes = try? fileSystem.attributes(of: url) else { return nil }
        let name = Self.displayName(for: url)

        if attributes.isSymlink || !attributes.isDirectory {
            return SizeNode(id: url, name: name, sizeBytes: max(0, attributes.sizeBytes), isDirectory: false)
        }

        guard let entries = try? fileSystem.children(of: url) else {
            return SizeNode(id: url, name: name, sizeBytes: 0, isDirectory: true)
        }

        if depth >= maxDepth {
            var total: Int64 = 0
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                total &+= totalSize(of: entry)
            }
            return SizeNode(id: url, name: name, sizeBytes: total, isDirectory: true)
        }

        var children: [SizeNode] = []
        children.reserveCapacity(entries.count)
        var total: Int64 = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if let child = walk(entry, depth: depth + 1, maxDepth: maxDepth) {
                total &+= child.sizeBytes
                children.append(child)
            }
        }
        return SizeNode(id: url, name: name, sizeBytes: total, isDirectory: true, children: children)
    }

    /// Recursive size of `url` without materializing nodes (used past `maxDepth`).
    private func totalSize(of url: URL) -> Int64 {
        guard let attributes = try? fileSystem.attributes(of: url) else { return 0 }
        if attributes.isSymlink || !attributes.isDirectory { return max(0, attributes.sizeBytes) }
        guard let entries = try? fileSystem.children(of: url) else { return 0 }
        var total: Int64 = 0
        for entry in entries { total &+= totalSize(of: entry) }
        return total
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
