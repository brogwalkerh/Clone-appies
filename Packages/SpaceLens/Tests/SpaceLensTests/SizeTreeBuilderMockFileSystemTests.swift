import CleanerCore
import CleanerCoreTesting
import Foundation
import Testing
import SpaceLens

@Suite("SizeTreeBuilder + MockFileSystem")
struct SizeTreeBuilderMockFileSystemTests {
    @Test("integration: known fixture tree via CleanerCoreTesting.MockFileSystem")
    func mockFixture() async throws {
        let fs: MockFileSystem = [
            "/Users/test/Library/Caches/app/a.bin": .file(size: 1_000),
            "/Users/test/Library/Caches/app/b.bin": .file(size: 250),
            "/Users/test/Library/Caches/empty": .directory,
            "/Users/test/Documents/report.pdf": .file(size: 4_000),
            "/Users/test/Documents/notes.txt": .file("hello"),
            "/Users/test/link": .symlink(to: "/Users/test/Library"),
            "/Applications/Foo.app": .package,
        ]
        let home = URL(fileURLWithPath: "/Users/test")
        let tree = try await SizeTreeBuilder(fileSystem: fs).build(root: home, maxDepth: 2)

        #expect(tree.sizeBytes == 1_000 + 250 + 4_000 + 5)
        #expect(tree.children.map(\.name) == ["Documents", "Library", "link"])

        let library = tree.find(id: home.appendingPathComponent("Library"))
        #expect(library?.sizeBytes == 1_250)
        // Caches is at depth 2 == maxDepth: full total, no children.
        let caches = library?.children.first { $0.name == "Caches" }
        #expect(caches?.sizeBytes == 1_250)
        #expect(caches?.children.isEmpty == true)

        let documents = tree.find(id: home.appendingPathComponent("Documents"))
        #expect(documents?.children.map(\.name) == ["report.pdf", "notes.txt"])
        #expect(documents?.children.map(\.sizeBytes) == [4_000, 5])

        // The symlink to /Users/test/Library is a leaf and is not followed.
        let link = tree.find(id: home.appendingPathComponent("link"))
        #expect(link?.isDirectory == false)
        #expect(link?.sizeBytes == 0)
        #expect(link?.children.isEmpty == true)

        // Nothing outside the root leaks in.
        #expect(tree.find(id: URL(fileURLWithPath: "/Applications/Foo.app")) == nil)
    }

    @Test("cancellation stops the walk inside a subtree, above and below maxDepth",
          arguments: [1, 10])
    func cancellationIsCheckedPerDirectory(maxDepth: Int) async throws {
        let mock: MockFileSystem = [
            "/root/top/a/trigger/b/c/d/e/file.bin": .file(size: 10),
            "/root/top/a/trigger/b/other/file.bin": .file(size: 10),
        ]
        let fs = CancellingFileSystem(base: mock, trigger: "trigger")
        await #expect(throws: CancellationError.self) {
            _ = try await SizeTreeBuilder(fileSystem: fs)
                .build(root: URL(fileURLWithPath: "/root"), maxDepth: maxDepth)
        }
        // Nothing below the directory that was being listed when the task was
        // cancelled may be listed afterwards.
        #expect(fs.log.listedAfterCancel == [])
    }
}

/// Lists through `base`; listing the directory named `trigger` cancels the
/// calling task, and every later listing is recorded.
private struct CancellingFileSystem: FileSystem {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var after: [String] = []

        var listedAfterCancel: [String] { lock.withLock { after } }
        func record(_ name: String, isTrigger: Bool) {
            lock.withLock {
                if cancelled { after.append(name) }
                if isTrigger { cancelled = true }
            }
        }
    }

    let base: MockFileSystem
    let trigger: String
    let log = Log()

    func exists(_ url: URL) -> Bool { base.exists(url) }
    func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
    func children(of url: URL) throws -> [URL] {
        let isTrigger = url.lastPathComponent == trigger
        log.record(url.lastPathComponent, isTrigger: isTrigger)
        if isTrigger { withUnsafeCurrentTask { $0?.cancel() } }
        return try base.children(of: url)
    }
    func contents(of url: URL) throws -> Data { try base.contents(of: url) }
    func homeDirectory() -> URL { base.homeDirectory() }
    func temporaryDirectory() -> URL { base.temporaryDirectory() }
}
