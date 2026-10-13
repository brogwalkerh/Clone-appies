import Foundation
import CleanerCore

/// Finds the support files an installed app keeps under `~/Library`, so the
/// uninstaller can offer them alongside the bundle.
public struct LeftoverResolver: Sendable {
    public static let scannerID = "applications.leftovers"

    private let fileSystem: any FileSystem
    private let protectedPaths: ProtectedPaths

    public init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, protectedPaths: .default)
    }

    /// Additional initializer with an explicit protected-path set.
    public init(fileSystem: any FileSystem, protectedPaths: ProtectedPaths) {
        self.fileSystem = fileSystem
        self.protectedPaths = protectedPaths
    }

    /// Existing leftover locations for `app`, as findings with category
    /// `applications.leftovers`, risk `.safe` and detail "<app name> support file".
    /// Returns `[]` for apps without a bundle identifier.
    public func leftovers(for app: InstalledApp, home: URL) async -> [Finding] {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return [] }
        let home = home.standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var names = [app.name]
        if app.bundleStem != app.name { names.append(app.bundleStem) }

        var candidates: [URL] = []
        func add(_ relative: String, _ name: String) {
            candidates.append(library.appendingPathComponent(relative, isDirectory: true).appendingPathComponent(name))
        }

        add("Application Support", bundleID)
        for name in names { add("Application Support", name) }
        add("Caches", bundleID)
        add("Preferences", "\(bundleID).plist")
        add("Containers", bundleID)
        candidates += matchingChildren(of: library.appendingPathComponent("Group Containers", isDirectory: true)) { name in
            if BundleIdentifier.name(name, containsComponents: bundleID) { return true }
            if let suffix = BundleIdentifier.vendorSuffix(bundleID) {
                return BundleIdentifier.name(name, containsComponents: suffix)
            }
            return false
        }
        add("Saved Application State", "\(bundleID).savedState")
        candidates += matchingChildren(of: library.appendingPathComponent("LaunchAgents", isDirectory: true)) { name in
            name.lowercased().hasPrefix(bundleID.lowercased()) && name.lowercased().hasSuffix(".plist")
        }
        add("Logs", bundleID)
        for name in names { add("Logs", name) }
        add("HTTPStorages", bundleID)
        add("HTTPStorages", "\(bundleID).binarycookies")
        add("WebKit", bundleID)
        add("Application Scripts", bundleID)
        add("Cookies", "\(bundleID).binarycookies")

        let sizer = FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                               skipsPackageContents: false, protectedPaths: protectedPaths)
        var seen = Set<String>()
        var findings: [Finding] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            let url = candidate.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            if protectedPaths.isProtected(url) { continue }
            guard let attributes = try? fileSystem.attributes(of: url) else { continue }
            let size: Int64
            if attributes.isDirectory {
                size = (try? await sizer.directorySize(url)) ?? 0
            } else if attributes.isSymlink {
                size = 0
            } else {
                size = attributes.sizeBytes
            }
            findings.append(Finding(path: url, sizeBytes: size, category: ApplicationsCategory.leftovers,
                                    scannerID: Self.scannerID, risk: .safe,
                                    detail: "\(app.name) support file",
                                    modifiedAt: attributes.modifiedAt,
                                    isDirectory: attributes.isDirectory))
        }
        return findings
    }

    private func matchingChildren(of directory: URL, _ predicate: (String) -> Bool) -> [URL] {
        fileSystem.readableChildren(of: directory).filter { predicate($0.lastPathComponent) }
    }
}
