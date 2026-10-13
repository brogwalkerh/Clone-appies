import Foundation
import CleanerCore

/// In-memory `FileSystem` built from a dictionary literal of absolute paths.
///
/// ```swift
/// let fs: MockFileSystem = [
///     "/Users/test/Library/Caches/app/a.bin": .file(size: 1_000),
///     "/Users/test/Library/Caches/empty": .directory,
///     "/Users/test/link": .symlink(to: "/Users/test/Library"),
///     "/Applications/Foo.app": .package,
/// ]
/// ```
/// Intermediate directories are created implicitly.
public struct MockFileSystem: FileSystem, ExpressibleByDictionaryLiteral {
    public enum Node: Sendable, Hashable {
        case file(size: Int64, modified: Date? = nil)
        case data(Data, modified: Date? = nil)
        case directory(modified: Date? = nil)
        case package(modified: Date? = nil)
        case symlink(to: String)

        public static var directory: Node { .directory(modified: nil) }
        public static var package: Node { .package(modified: nil) }
        public static func file(_ text: String, modified: Date? = nil) -> Node {
            .data(Data(text.utf8), modified: modified)
        }
    }

    private var nodes: [String: Node]
    private var childrenIndex: [String: [String]]
    public let home: URL
    public let temp: URL

    public init(_ entries: [String: Node],
                home: URL = URL(fileURLWithPath: "/Users/test", isDirectory: true),
                temp: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)) {
        self.home = home.standardizedFileURL
        self.temp = temp.standardizedFileURL
        var nodes: [String: Node] = ["/": .directory]
        for (path, node) in entries {
            let normalized = Self.normalize(path)
            nodes[normalized] = node
            // Create implicit parents.
            var parent = Self.parent(of: normalized)
            while parent != "/" {
                if nodes[parent] == nil { nodes[parent] = .directory }
                parent = Self.parent(of: parent)
            }
        }
        for path in [self.home.path, self.temp.path] {
            let normalized = Self.normalize(path)
            var current = normalized
            while current != "/" {
                if nodes[current] == nil { nodes[current] = .directory }
                current = Self.parent(of: current)
            }
        }
        var index: [String: [String]] = [:]
        for path in nodes.keys where path != "/" {
            index[Self.parent(of: path), default: []].append(path)
        }
        for key in index.keys { index[key]?.sort() }
        self.nodes = nodes
        self.childrenIndex = index
    }

    public init(dictionaryLiteral elements: (String, Node)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    // MARK: FileSystem

    public func exists(_ url: URL) -> Bool {
        nodes[Self.normalize(url.path)] != nil
    }

    public func attributes(of url: URL) throws -> FileAttributes {
        let path = Self.normalize(url.path)
        guard let node = nodes[path] else { throw FileSystemError.notFound(url) }
        switch node {
        case .file(let size, let modified):
            return FileAttributes(sizeBytes: size, modifiedAt: modified)
        case .data(let data, let modified):
            return FileAttributes(sizeBytes: Int64(data.count), modifiedAt: modified)
        case .directory(let modified):
            return FileAttributes(sizeBytes: 0, modifiedAt: modified, isDirectory: true)
        case .package(let modified):
            return FileAttributes(sizeBytes: 0, modifiedAt: modified, isDirectory: true, isPackage: true)
        case .symlink:
            return FileAttributes(sizeBytes: 0, isSymlink: true)
        }
    }

    public func children(of url: URL) throws -> [URL] {
        let path = Self.normalize(url.path)
        guard let node = nodes[path] else { throw FileSystemError.notFound(url) }
        switch node {
        case .directory, .package:
            return (childrenIndex[path] ?? []).map { URL(fileURLWithPath: $0) }
        default:
            throw FileSystemError.notADirectory(url)
        }
    }

    public func contents(of url: URL) throws -> Data {
        let path = Self.normalize(url.path)
        guard let node = nodes[path] else { throw FileSystemError.notFound(url) }
        switch node {
        case .data(let data, _): return data
        case .file(let size, _): return Data(count: Int(min(size, 1 << 20)))
        default: throw FileSystemError.notAFile(url)
        }
    }

    public func homeDirectory() -> URL { home }
    public func temporaryDirectory() -> URL { temp }

    /// Target of a symlink node, if `url` is one.
    public func symlinkDestination(_ url: URL) -> URL? {
        if case .symlink(let target) = nodes[Self.normalize(url.path)] {
            return URL(fileURLWithPath: target)
        }
        return nil
    }

    /// All absolute paths in the tree, sorted.
    public var allPaths: [String] { nodes.keys.sorted() }

    // MARK: Helpers

    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
