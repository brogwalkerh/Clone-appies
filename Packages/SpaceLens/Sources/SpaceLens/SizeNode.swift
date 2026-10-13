import Foundation

/// One entry of a disk-usage tree: a file or a directory with its total size.
///
/// `id` is the standardized file URL of the entry. Directory sizes are the sum
/// of everything beneath them, even when `children` was truncated by a depth
/// limit (see `SizeTreeBuilder`).
public struct SizeNode: Sendable, Hashable, Identifiable {
    public let id: URL
    public let name: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public var children: [SizeNode]

    public init(id: URL, name: String, sizeBytes: Int64, isDirectory: Bool, children: [SizeNode] = []) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Returns a copy whose children (recursively) are ordered by size descending.
    /// Ties are broken by `name`, then by `id.path`, so the order is deterministic.
    public func sorted() -> SizeNode {
        var copy = self
        copy.children = children
            .map { $0.sorted() }
            .sorted(by: SizeNode.sizeDescending)
        return copy
    }

    /// Depth-first lookup of a node by its `id`. Returns `self` when the ids match.
    public func find(id: URL) -> SizeNode? {
        if self.id == id { return self }
        for child in children {
            if let hit = child.find(id: id) { return hit }
        }
        return nil
    }

    /// Stable "largest first" ordering shared by `sorted()` and the layout engine.
    static func sizeDescending(_ a: SizeNode, _ b: SizeNode) -> Bool {
        if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
        if a.name != b.name { return a.name < b.name }
        return a.id.path < b.id.path
    }
}
