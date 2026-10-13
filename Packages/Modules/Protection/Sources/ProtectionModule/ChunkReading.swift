import Foundation
import CleanerCore

/// A `FileSystem` that can stream a file without loading it whole.
/// `LocalFileSystem` conforms (via `FileHandle`); any other implementation
/// falls back to `contents(of:)` through the `FileSystem` extension below.
/// Internal on purpose: ClutterModule ships a public twin and a target that
/// imports both must not see two `readRange`s.
protocol ChunkReadableFileSystem: FileSystem {
    func readHead(of url: URL, length: Int) throws -> Data
    func streamChunks(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws
}

extension LocalFileSystem: ChunkReadableFileSystem {
    func readHead(of url: URL, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try Self.openForReading(url)
        defer { try? handle.close() }
        do {
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw FileSystemError.unreadable(url, "\(error)")
        }
    }

    func streamChunks(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        let handle = try Self.openForReading(url)
        defer { try? handle.close() }
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw FileSystemError.unreadable(url, "\(error)")
            }
            guard let chunk, !chunk.isEmpty else { return }
            try body(chunk)
            if chunk.count < chunkSize { return }
        }
    }

    private static func openForReading(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                throw FileSystemError.notFound(url)
            }
            throw FileSystemError.unreadable(url, "\(error)")
        }
    }
}

extension FileSystem {
    /// First `length` bytes of the file (fewer for a short file).
    func fileHead(of url: URL, length: Int) throws -> Data {
        if let chunked = self as? any ChunkReadableFileSystem {
            return try chunked.readHead(of: url, length: length)
        }
        return try contents(of: url).prefix(length)
    }

    /// Streams the whole file in `chunkSize` pieces when the implementation
    /// can, otherwise reads it whole and hands it over in `chunkSize` slices.
    func forEachFileChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        if let chunked = self as? any ChunkReadableFileSystem {
            try chunked.streamChunks(of: url, chunkSize: chunkSize, body)
            return
        }
        let data = try contents(of: url)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            try body(data.subdata(in: offset..<end))
            offset = end
        }
    }
}
