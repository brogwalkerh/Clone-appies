import Foundation
import Testing
@testable import CleanerCore
import CleanerCoreTesting

@Suite("FileWalker")
struct FileWalkerTests {
    private func collect(_ walker: FileWalker, _ root: URL, maxDepth: Int? = nil) async throws -> [String: FileAttributes] {
        var result: [String: FileAttributes] = [:]
        for try await (url, attributes) in walker.walk(root, maxDepth: maxDepth) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = attributes
        }
        return result
    }

    @Test func walksEverythingIncludingDirectories() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "a.txt": .file(size: 10),
            "dir/b.txt": .file(size: 20),
            "dir/sub/c.txt": .file(size: 30),
            "empty": .directory,
        ])
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: .none)
        let entries = try await collect(walker, fixture.root)
        #expect(Set(entries.keys) == ["a.txt", "dir", "dir/b.txt", "dir/sub", "dir/sub/c.txt", "empty"])
        #expect(entries["dir"]?.isDirectory == true)
        #expect(entries["dir"]?.sizeBytes == 0)
        #expect(entries["a.txt"]?.isDirectory == false)
        #expect((entries["a.txt"]?.sizeBytes ?? 0) >= 10)
        #expect(entries["a.txt"]?.modifiedAt != nil)
    }

    @Test func respectsDepthLimit() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "a.txt": .file(size: 1),
            "dir/b.txt": .file(size: 1),
            "dir/sub/c.txt": .file(size: 1),
        ])
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: .none)
        let depth1 = try await collect(walker, fixture.root, maxDepth: 1)
        #expect(Set(depth1.keys) == ["a.txt", "dir"])
        let depth2 = try await collect(walker, fixture.root, maxDepth: 2)
        #expect(Set(depth2.keys) == ["a.txt", "dir", "dir/b.txt", "dir/sub"])
        let depth0 = try await collect(walker, fixture.root, maxDepth: 0)
        #expect(depth0.isEmpty)
    }

    @Test func doesNotFollowSymlinksByDefault() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "real/file.txt": .file(size: 5),
            "link": .symlink(to: "real"),
            "filelink": .symlink(to: "real/file.txt"),
        ])
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: .none)
        let entries = try await collect(walker, fixture.root)
        #expect(Set(entries.keys) == ["real", "real/file.txt", "link", "filelink"])
        #expect(entries["link"]?.isSymlink == true)
        #expect(entries["link"]?.isDirectory == false)
        #expect(entries["filelink"]?.isSymlink == true)
    }

    @Test func followingSymlinksIsLoopSafe() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "real/file.txt": .file(size: 5),
            "real/loop": .symlink(to: "real"),
            "real/up": .symlink(to: "."),
            "link": .symlink(to: "real"),
        ])
        let walker = FileWalker(fileSystem: LocalFileSystem(), followsSymlinks: true, protectedPaths: .none)
        var count = 0
        for try await _ in walker.walk(fixture.root) {
            count += 1
            #expect(count < 100, "walker is looping")
            if count >= 100 { break }
        }
        // real, real/file.txt, real/loop, real/up, link (already-visited targets are not re-entered)
        #expect(count == 5)
    }

    @Test func skipsProtectedSubtree() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "ok/a.txt": .file(size: 1),
            "protected/secret.txt": .file(size: 1),
            "protected/deeper/x.txt": .file(size: 1),
            "protectedish/b.txt": .file(size: 1),
        ])
        let protected = ProtectedPaths(prefixes: [fixture.url("protected")])
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: protected)
        let entries = try await collect(walker, fixture.root)
        #expect(Set(entries.keys) == ["ok", "ok/a.txt", "protectedish", "protectedish/b.txt"])

        // A protected root yields nothing at all.
        let none = try await collect(walker, fixture.url("protected"))
        #expect(none.isEmpty)
    }

    @Test func throwsForMissingRoot() async {
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: .none)
        let missing = URL(fileURLWithPath: "/definitely/not/here/\(UUID().uuidString)")
        await #expect(throws: FileSystemError.notFound(missing.standardizedFileURL)) {
            for try await _ in walker.walk(missing) {}
        }
    }

    @Test func directorySizeSumsFiles() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        try fixture.build([
            "a.bin": .file(size: 4096),
            "dir/b.bin": .file(size: 8192),
            "dir/link": .symlink(to: "a.bin"),
        ])
        let walker = FileWalker(fileSystem: LocalFileSystem(), protectedPaths: .none)
        let size = try await walker.directorySize(fixture.root)
        #expect(size >= 4096 + 8192)
        #expect(size < 2 * (4096 + 8192) + 16384) // allocation slack, symlink not double counted
    }

    @Test func worksAgainstMockFileSystemAndSkipsPackages() async throws {
        let fs: MockFileSystem = [
            "/Users/test/Library/Caches/app/a.bin": .file(size: 1_000),
            "/Users/test/Library/Caches/app/b.bin": .file(size: 2_000),
            "/Users/test/Applications/Foo.app": .package,
            "/Users/test/Applications/Foo.app/Contents/MacOS/Foo": .file(size: 50_000),
        ]
        let walker = FileWalker(fileSystem: fs, protectedPaths: .none)
        var seen: [String] = []
        for try await (url, _) in walker.walk(fs.homeDirectory()) {
            seen.append(url.path)
        }
        #expect(seen.contains("/Users/test/Applications/Foo.app"))
        #expect(!seen.contains("/Users/test/Applications/Foo.app/Contents"))
        #expect(seen.contains("/Users/test/Library/Caches/app/b.bin"))
        let size = try await walker.directorySize(URL(fileURLWithPath: "/Users/test/Library"))
        #expect(size == 3_000)

        let descending = FileWalker(fileSystem: fs, skipsPackageContents: false, protectedPaths: .none)
        let size2 = try await descending.directorySize(URL(fileURLWithPath: "/Users/test"))
        #expect(size2 == 53_000)
    }
}
