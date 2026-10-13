import Foundation

/// Abstracts the filesystem so scanners can be tested against fixtures.
public protocol FileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    func attributes(of url: URL) throws -> FileAttributes
    func children(of url: URL) throws -> [URL]           // non-recursive, no hidden filtering
    func contents(of url: URL) throws -> Data           // for small files (plists, rules)
    func homeDirectory() -> URL
    func temporaryDirectory() -> URL
}

public struct FileAttributes: Sendable, Hashable {
    public let sizeBytes: Int64         // allocated size for files, 0 for directories
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool          // macOS bundle; always false on Linux

    public init(sizeBytes: Int64, modifiedAt: Date? = nil, isDirectory: Bool = false,
                isSymlink: Bool = false, isPackage: Bool = false) {
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isPackage = isPackage
    }
}

public enum FileSystemError: Error, Sendable, Hashable {
    case notFound(URL)
    case notADirectory(URL)
    case notAFile(URL)
    case unreadable(URL, String)
}

/// `FileSystem` backed by `FileManager`. Attributes are read with lstat
/// semantics (symlinks are reported as symlinks, never followed).
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func attributes(of url: URL) throws -> FileAttributes {
        let path = url.path
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                throw FileSystemError.notFound(url)
            }
            throw FileSystemError.unreadable(url, "\(error)")
        }
        let type = attrs[.type] as? FileAttributeType
        let isSymlink = type == .typeSymbolicLink
        let isDirectory = type == .typeDirectory
        let modified = attrs[.modificationDate] as? Date

        var size: Int64 = 0
        if !isDirectory {
            size = Self.int64(attrs[.size])
        }
        var isPackage = false
        #if canImport(Darwin)
        if !isSymlink {
            let keys: Set<URLResourceKey> = [
                .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            ]
            if let values = try? url.resourceValues(forKeys: keys) {
                isPackage = values.isPackage ?? false
                if !isDirectory {
                    if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                        size = Int64(allocated)
                    }
                }
            }
        }
        #endif
        return FileAttributes(sizeBytes: size, modifiedAt: modified, isDirectory: isDirectory,
                              isSymlink: isSymlink, isPackage: isPackage)
    }

    public func children(of url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(url)
        }
        guard isDir.boolValue else { throw FileSystemError.notADirectory(url) }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            throw FileSystemError.unreadable(url, "\(error)")
        }
        return names.sorted().map { url.appendingPathComponent($0) }
    }

    public func contents(of url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                throw FileSystemError.notFound(url)
            }
            throw FileSystemError.unreadable(url, "\(error)")
        }
    }

    public func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let v as Int64: return v
        case let v as UInt64: return Int64(clamping: v)
        case let v as Int: return Int64(v)
        case let v as UInt: return Int64(clamping: v)
        case let v as NSNumber: return v.int64Value
        default: return 0
        }
    }
}
