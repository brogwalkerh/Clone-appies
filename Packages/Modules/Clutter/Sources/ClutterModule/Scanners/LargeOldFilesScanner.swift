import Foundation
import CleanerCore

/// Large & Old: files at least `minSizeBytes` (category `clutter.largeFiles`)
/// or not modified for `minAge` (category `clutter.oldFiles`) under the
/// user's home folders. A file that is both large and old is reported once,
/// as a large file.
public struct LargeOldFilesScanner: CleanerScanner {
    public static let id = "clutter.largeOld"
    public static let largeFilesCategoryID = "clutter.largeFiles"
    public static let oldFilesCategoryID = "clutter.oldFiles"
    /// Home-relative folders scanned by default, shared with the other
    /// clutter scanners.
    public static let defaultRoots = ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"]

    public let displayName = "Large & Old Files"
    public let module = ModuleID.clutter

    public let minSizeBytes: Int64
    public let minAge: TimeInterval
    public let roots: [String]

    public init(minSizeBytes: Int64 = 100_000_000, minAge: TimeInterval = 180 * 86_400,
                roots: [String] = LargeOldFilesScanner.defaultRoots) {
        self.minSizeBytes = minSizeBytes
        self.minAge = minAge
        self.roots = roots
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let minSizeBytes = self.minSizeBytes
        let minAge = self.minAge
        let roots = self.roots
        return makeFindingStream { emitter in
            try await context.forEachRegularFile(under: context.scanRoots(roots)) { url, attributes in
                if attributes.sizeBytes >= minSizeBytes {
                    emitter.emit(Finding(path: url, sizeBytes: attributes.sizeBytes,
                                         category: ClutterCategory.largeFiles, scannerID: Self.id,
                                         risk: .caution, detail: Self.largeDetail(attributes.sizeBytes),
                                         modifiedAt: attributes.modifiedAt, isDirectory: false))
                    return
                }
                guard let modified = attributes.modifiedAt else { return }
                let age = context.now.timeIntervalSince(modified)
                guard age >= minAge else { return }
                emitter.emit(Finding(path: url, sizeBytes: attributes.sizeBytes,
                                     category: ClutterCategory.oldFiles, scannerID: Self.id,
                                     risk: .caution, detail: Self.oldDetail(age: age),
                                     modifiedAt: modified, isDirectory: false))
            }
        }
    }

    /// "Large file, 150 MB" (decimal megabytes, whole number).
    static func largeDetail(_ bytes: Int64) -> String {
        "Large file, \(bytes / 1_000_000) MB"
    }

    /// "Not opened in 6 months" (30-day months, whole number).
    static func oldDetail(age: TimeInterval) -> String {
        "Not opened in \(Int(age / (30 * 86_400))) months"
    }
}
