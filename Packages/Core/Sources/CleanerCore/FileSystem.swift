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
    public let sizeBytes: Int64         // allocated (on-disk) size for files, 0 for directories
    public let logicalSizeBytes: Int64  // byte length of the contents; equals sizeBytes on Linux
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool          // macOS bundle; always false on Linux

    /// `logicalSizeBytes` defaults to `sizeBytes` when omitted.
    public init(sizeBytes: Int64, logicalSizeBytes: Int64? = nil, modifiedAt: Date? = nil,
                isDirectory: Bool = false, isSymlink: Bool = false, isPackage: Bool = false) {
        self.sizeBytes = sizeBytes
        self.logicalSizeBytes = logicalSizeBytes ?? sizeBytes
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

        // `.size` is st_size: the logical length of the contents. On Linux that
        // is also what we report as the allocated size.
        var logicalSize: Int64 = 0
        if !isDirectory {
            logicalSize = Self.int64(attrs[.size])
        }
        var allocatedSize = logicalSize
        var isPackage = false
        #if canImport(Darwin)
        if !isSymlink {
            let keys: Set<URLResourceKey> = [
                .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            ]
            if let values = try? url.resourceValues(forKeys: keys) {
                isPackage = values.isPackage ?? false
                if !isDirectory {
                    if let logical = values.fileSize {
                        logicalSize = Int64(logical)
                    }
                    // APFS compression and clonefile make this differ from the
                    // logical size, in either direction.
                    if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                        allocatedSize = Int64(allocated)
                    } else {
                        allocatedSize = logicalSize
                    }
                }
            }
        }
        #endif
        return FileAttributes(sizeBytes: allocatedSize, logicalSizeBytes: logicalSize,
                              modifiedAt: modified, isDirectory: isDirectory,
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
