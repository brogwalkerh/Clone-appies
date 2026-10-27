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
}
