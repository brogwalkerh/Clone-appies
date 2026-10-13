import Foundation
import CleanerCore

/// A `FileSystem` that can read a byte range without loading the whole file.
///
/// `LocalFileSystem` conforms (via `FileHandle`). Any other implementation
/// falls back to `contents(of:)` sliced in memory through the
/// `FileSystem.readRange(of:offset:length:)` extension below.
public protocol RangeReadableFileSystem: FileSystem {
    /// Up to `length` bytes starting at `offset`. Short (or empty) when the
    /// range runs past the end of the file.
    func readRange(of url: URL, offset: Int64, length: Int) throws -> Data

    /// Streams the whole file in `chunkSize` pieces, holding one chunk at a time.
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws
}

public extension RangeReadableFileSystem {
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        var offset: Int64 = 0
        while true {
            let chunk = try readRange(of: url, offset: offset, length: chunkSize)
            if chunk.isEmpty { return }
            try body(chunk)
            offset += Int64(chunk.count)
            if chunk.count < chunkSize { return }
        }
    }
}

extension LocalFileSystem: RangeReadableFileSystem {
    public func readRange(of url: URL, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try Self.openForReading(url)
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw FileSystemError.unreadable(url, "\(error)")
        }
    }

    public func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
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

public extension FileSystem {
    /// Reads `length` bytes at `offset`, using the range-reading fast path when
    /// the implementation offers one and `contents(of:)` otherwise.
    func readRange(of url: URL, offset: Int64, length: Int) throws -> Data {
        if let ranged = self as? any RangeReadableFileSystem {
            return try ranged.readRange(of: url, offset: offset, length: length)
        }
        let data = try contents(of: url)
        guard length > 0, offset >= 0, offset < Int64(data.count) else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = min(data.endIndex, start + length)
        return Data(data[start..<end])
    }

    /// Full SHA-256 of a file, streamed in `chunkSize` pieces when possible so
    /// that at most one chunk is resident at a time.
    func sha256Digest(of url: URL, chunkSize: Int = 1 << 20) throws -> [UInt8] {
        var hasher = StreamingSHA256()
        if let ranged = self as? any RangeReadableFileSystem {
            try ranged.forEachChunk(of: url, chunkSize: chunkSize) { chunk in
                try Task.checkCancellation()
                hasher.update(chunk)
            }
        } else {
            hasher.update(try contents(of: url))
        }
        return hasher.finalize()
    }
}
