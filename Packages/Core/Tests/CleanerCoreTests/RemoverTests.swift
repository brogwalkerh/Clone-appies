import Foundation
import Testing
@testable import CleanerCore
import CleanerCoreTesting

private let category = FindingCategory(id: "test.cat", displayName: "Test", module: .cleanup)

private func finding(_ url: URL, size: Int64 = 0, isDirectory: Bool = false) -> Finding {
    Finding(path: url, sizeBytes: size, category: category, scannerID: "test", risk: .safe, isDirectory: isDirectory)
}

@Suite("TrashRemover")
struct TrashRemoverTests {
    @Test func trashAndUndoRoundTrip() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let trash = fixture.url("Trash/files")
        let fileA = try fixture.file("data/a.txt", size: 100)
        let dirB = try fixture.directory("data/b")
        try fixture.file("data/b/inner.txt", size: 50)
        let missing = fixture.url("data/missing.txt")

        let remover = TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: trash)
        let progressLog = ProgressLog()
        let manifest = try await remover.remove(
            [finding(fileA, size: 100), finding(dirB, size: 50, isDirectory: true), finding(missing, size: 7)],
            mode: .trash,
            progress: { done, total in progressLog.record(done, total) })

        #expect(manifest.mode == .trash)
        #expect(manifest.records.count == 3)
        #expect(manifest.records[0].succeeded)
        #expect(manifest.records[1].succeeded)
        #expect(!manifest.records[2].succeeded)
        #expect(manifest.records[2].error != nil)
        #expect(manifest.bytesReclaimed == 150)
        #expect(progressLog.entries.map { "\($0.0)/\($0.1)" } == ["1/3", "2/3", "3/3"])

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: dirB.path))
        let trashedA = try #require(manifest.records[0].trashedTo)
        #expect(trashedA.path.hasPrefix(trash.path))
        #expect(FileManager.default.fileExists(atPath: trashedA.path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("Trash/info/a.txt.trashinfo").path))

        // Manifest survives a Codable round trip.
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RemovalManifest.self, from: data)
        #expect(decoded == manifest)

        // Undo restores both successful items.
        let restored = try await remover.undo(decoded)
        #expect(restored.count == 3)
        #expect(restored[0].succeeded)
        #expect(restored[1].succeeded)
        #expect(!restored[2].succeeded)
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("data/b/inner.txt").path))
        #expect(!FileManager.default.fileExists(atPath: trashedA.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Trash/info/a.txt.trashinfo").path))
    }

    @Test func trashUsesUniqueNamesForCollisions() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let trash = fixture.url("Trash/files")
        let first = try fixture.file("one/report.txt", size: 1)
        let second = try fixture.file("two/report.txt", size: 1)
        let remover = TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: trash)
        let manifest = try await remover.remove([finding(first), finding(second)], mode: .trash, progress: nil)
        let destinations = Set(manifest.records.compactMap { $0.trashedTo?.lastPathComponent })
        #expect(destinations == ["report.txt", "report 2.txt"])
    }

    @Test func undoRefusesToOverwrite() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let trash = fixture.url("Trash/files")
        let file = try fixture.file("a.txt", size: 1)
        let remover = TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: trash)
        let manifest = try await remover.remove([finding(file)], mode: .trash, progress: nil)
        // Something new appeared at the original location.
        try fixture.file("a.txt", size: 2)
        let restored = try await remover.undo(manifest)
        #expect(restored.count == 1)
        #expect(!restored[0].succeeded)
        #expect(restored[0].error?.contains("exists") == true)
    }

    @Test func permanentRemoval() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let file = try fixture.file("gone.txt", size: 10)
        let remover = TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: fixture.url("Trash/files"))
        let manifest = try await remover.remove([finding(file, size: 10)], mode: .permanent, progress: nil)
        #expect(manifest.records[0].succeeded)
        #expect(manifest.records[0].trashedTo == nil)
        #expect(manifest.bytesReclaimed == 10)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let undone = try await remover.undo(manifest)
        #expect(!undone[0].succeeded)
    }

    #if !canImport(Darwin)
    @Test func defaultLinuxTrashDirectoryHonoursXDG() {
        let dir = TrashRemover.xdgTrashFilesDirectory()
        #expect(dir.path.hasSuffix("Trash/files"))
    }
    #endif
}

@Suite("GuardedRemover")
struct GuardedRemoverTests {
    @Test func refusesProtectedBatchBeforeTouchingAnything() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let ok = try fixture.file("ok.txt", size: 1)
        let protectedDir = try fixture.directory("protected")
        let secret = try fixture.file("protected/secret.txt", size: 1)

        let inner = TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: fixture.url("Trash/files"))
        let guarded = GuardedRemover(wrapping: inner, protectedPaths: ProtectedPaths(prefixes: [protectedDir]))

        await #expect(throws: RemovalError.protectedPath(secret)) {
            _ = try await guarded.remove([finding(ok), finding(secret)], mode: .trash, progress: nil)
        }
        // Nothing was removed, not even the unprotected item that came first.
        #expect(FileManager.default.fileExists(atPath: ok.path))
        #expect(FileManager.default.fileExists(atPath: secret.path))

        // Unprotected batches pass through.
        let manifest = try await guarded.remove([finding(ok, size: 1)], mode: .trash, progress: nil)
        #expect(manifest.bytesReclaimed == 1)
        #expect(!FileManager.default.fileExists(atPath: ok.path))
        let restored = try await guarded.undo(manifest)
        #expect(restored[0].succeeded)
        #expect(FileManager.default.fileExists(atPath: ok.path))
    }
}

/// Thread-safe progress recorder for the `@Sendable` progress callback.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(Int, Int)] = []
    var entries: [(Int, Int)] { lock.withLock { _entries } }
    func record(_ done: Int, _ total: Int) { lock.withLock { _entries.append((done, total)) } }
}
