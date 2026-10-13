import Foundation
import CleanerCore

/// Creates real directory trees in a temporary location for integration tests.
///
/// ```swift
/// let fixture = try FixtureBuilder()
/// defer { try? fixture.remove() }
/// try fixture.file("Library/Caches/a.bin", size: 4096)
/// try fixture.symlink("link", to: "Library")
/// ```
public struct FixtureBuilder: Sendable {
    public let root: URL

    /// Creates a fresh, unique directory under `FileManager.temporaryDirectory`.
    public init(name: String = "fixture") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerCore-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base.standardizedFileURL
    }

    /// Uses an existing directory as the root.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    @discardableResult
    public func directory(_ relativePath: String) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file of `size` zero bytes (or `contents` when given).
    @discardableResult
    public func file(_ relativePath: String, size: Int = 0, contents: Data? = nil,
                     modified: Date? = nil) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = contents ?? Data(count: size)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Creates a symlink at `relativePath` pointing at `destination`.
    /// A relative destination is interpreted relative to the fixture root.
    @discardableResult
    public func symlink(_ relativePath: String, to destination: String) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let target = destination.hasPrefix("/") ? destination : self.url(destination).path
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url
    }

    /// Materializes a `MockFileSystem`-style tree (relative paths) on disk.
    public func build(_ tree: [String: MockFileSystem.Node]) throws {
        for (path, node) in tree.sorted(by: { $0.key < $1.key }) {
            switch node {
            case .file(let size, let modified):
                try file(path, size: Int(size), modified: modified)
            case .data(let data, let modified):
                try file(path, contents: data, modified: modified)
            case .directory, .package:
                try directory(path)
            case .symlink(let target):
                try symlink(path, to: target)
            }
        }
    }

    /// Deletes the fixture tree.
    public func remove() throws {
        try FileManager.default.removeItem(at: root)
    }
}
