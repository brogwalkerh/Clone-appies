import CleanerCore
import Foundation
import Testing
@testable import SpaceLens

/// In-memory `FileSystem` fixture: a known tree with a symlink and an unreadable directory.
private struct FixtureFileSystem: FileSystem {
    enum Entry: Sendable {
        case file(Int64)
        case dir([String])
        case symlink
        case unreadableDir
        case brokenAttributes
    }

    let root: URL
    let entries: [String: Entry]  // keyed by path relative to root ("" = root)

    struct Failure: Error {}

    private func key(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if p == r { return "" }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    func exists(_ url: URL) -> Bool { entries[key(url)] != nil }

    func attributes(of url: URL) throws -> FileAttributes {
        guard let e = entries[key(url)] else { throw Failure() }
        switch e {
        case .file(let size):
            return FileAttributes(sizeBytes: size, modifiedAt: nil, isDirectory: false, isSymlink: false, isPackage: false)
        case .dir, .unreadableDir:
            return FileAttributes(sizeBytes: 0, modifiedAt: nil, isDirectory: true, isSymlink: false, isPackage: false)
        case .symlink:
            // Points at a huge directory elsewhere; must not be followed.
            return FileAttributes(sizeBytes: 12, modifiedAt: nil, isDirectory: true, isSymlink: true, isPackage: false)
        case .brokenAttributes:
            throw Failure()
        }
    }

    func children(of url: URL) throws -> [URL] {
        guard let e = entries[key(url)] else { throw Failure() }
        switch e {
        case .dir(let names):
            return names.map { url.appendingPathComponent($0) }
        default:
            throw Failure()
        }
    }

    func contents(of url: URL) throws -> Data { throw Failure() }
    func homeDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root.appendingPathComponent("tmp") }
}

@Suite("SizeTreeBuilder")
struct SizeTreeBuilderTests {
    let root = URL(fileURLWithPath: "/fixture")

    /// Known fixture:
    /// /fixture
    ///   a.bin           100
    ///   docs/           (dir)  total 1_300
    ///     notes.txt     300
    ///     deep/         total 1_000
    ///       d1/         total 1_000
    ///         big.bin   1_000
    ///   link -> elsewhere (symlink, size 12, never followed)
    ///   locked/         unreadable directory (children throws) -> size 0
    ///   ghost           attributes throw -> skipped
    fileprivate var fixture: FixtureFileSystem {
        FixtureFileSystem(root: root, entries: [
            "": .dir(["a.bin", "docs", "link", "locked", "ghost"]),
            "a.bin": .file(100),
            "docs": .dir(["notes.txt", "deep"]),
            "docs/notes.txt": .file(300),
            "docs/deep": .dir(["d1"]),
            "docs/deep/d1": .dir(["big.bin"]),
            "docs/deep/d1/big.bin": .file(1_000),
            "link": .symlink,
            "locked": .unreadableDir,
            "ghost": .brokenAttributes,
        ])
    }

    @Test("sums match the fixture tree and output is sorted")
    func sums() async throws {
        let tree = try await SizeTreeBuilder(fileSystem: fixture, maxConcurrency: 2).build(root: root, maxDepth: 3)
        #expect(tree.id == root)
        #expect(tree.isDirectory)
        #expect(tree.sizeBytes == 100 + 1_300 + 12 + 0)
        #expect(tree.children.map(\.name) == ["docs", "a.bin", "link", "locked"])  // ghost skipped

        let docs = tree.find(id: root.appendingPathComponent("docs"))
        #expect(docs?.sizeBytes == 1_300)
        #expect(docs?.children.map(\.name) == ["deep", "notes.txt"])

        let d1 = tree.find(id: root.appendingPathComponent("docs/deep/d1"))
        #expect(d1?.sizeBytes == 1_000)
        #expect(d1?.children.isEmpty == true)   // depth 3 == maxDepth: size but no children

        let link = tree.find(id: root.appendingPathComponent("link"))
        #expect(link?.isDirectory == false)
        #expect(link?.sizeBytes == 12)
        #expect(link?.children.isEmpty == true)

        let locked = tree.find(id: root.appendingPathComponent("locked"))
        #expect(locked?.isDirectory == true)
        #expect(locked?.sizeBytes == 0)
    }

    @Test("maxDepth truncates children but keeps totals")
    func depthTruncation() async throws {
        let builder = SizeTreeBuilder(fileSystem: fixture)
        let shallow = try await builder.build(root: root, maxDepth: 1)
        #expect(shallow.sizeBytes == 1_412)
        let docs = shallow.find(id: root.appendingPathComponent("docs"))
        #expect(docs?.sizeBytes == 1_300)
        #expect(docs?.children.isEmpty == true)

        let zero = try await builder.build(root: root, maxDepth: 0)
        #expect(zero.sizeBytes == 1_412)
        #expect(zero.children.isEmpty)
    }

    @Test("a file root is returned as a leaf")
    func fileRoot() async throws {
        let tree = try await SizeTreeBuilder(fileSystem: fixture).build(root: root.appendingPathComponent("a.bin"))
        #expect(tree.isDirectory == false)
        #expect(tree.sizeBytes == 100)
        #expect(tree.children.isEmpty)
    }

    @Test("an unreadable root throws")
    func unreadableRoot() async {
        await #expect(throws: (any Error).self) {
            _ = try await SizeTreeBuilder(fileSystem: fixture).build(root: root.appendingPathComponent("ghost"))
        }
    }

    @Test("integration: real temp directory via LocalFileSystem")
    func realDirectory() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("SpaceLens-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        try Data(repeating: 1, count: 4_096).write(to: base.appendingPathComponent("top.bin"))
        try Data(repeating: 2, count: 8_192).write(to: base.appendingPathComponent("sub/mid.bin"))
        try Data(repeating: 3, count: 1_024).write(to: base.appendingPathComponent("sub/inner/leaf.bin"))

        let tree = try await SizeTreeBuilder(fileSystem: LocalFileSystem()).build(root: base, maxDepth: 2)
        #expect(tree.isDirectory)
        #expect(tree.children.map(\.name) == ["sub", "top.bin"])

        // Allocated size may exceed the logical size on some filesystems; it is
        // never smaller, and directory totals must equal the sum of their files.
        let sub = tree.find(id: base.standardizedFileURL.appendingPathComponent("sub"))
        let top = tree.find(id: base.standardizedFileURL.appendingPathComponent("top.bin"))
        #expect(top.map { $0.sizeBytes >= 4_096 } == true)
        #expect(sub.map { $0.sizeBytes >= 8_192 + 1_024 } == true)
        #expect(tree.sizeBytes == (sub?.sizeBytes ?? 0) + (top?.sizeBytes ?? 0))
        let inner = sub?.children.first { $0.name == "inner" }
        #expect(inner != nil)
        #expect(inner?.children.isEmpty == true)  // depth 2 == maxDepth
        #expect(inner.map { $0.sizeBytes >= 1_024 } == true)
    }
}
