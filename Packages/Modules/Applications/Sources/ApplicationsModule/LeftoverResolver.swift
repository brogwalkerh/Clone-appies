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
    ///
    /// `app.name` and the bundle identifier come from the app's own
    /// Info.plist and are untrusted: a name such as `../../Documents` must
    /// never turn a user folder into a "support file". Names that are not a
    /// single safe path component are dropped (an unsafe identifier yields
    /// nothing at all), and every candidate must sit directly inside the
    /// `~/Library` subfolder it was built for.
    public func leftovers(for app: InstalledApp, home: URL) async -> [Finding] {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
              BundleIdentifier.isSafePathComponent(bundleID) else { return [] }
        let home = home.standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var names: [String] = []
        for name in [app.name, app.bundleStem]
        where BundleIdentifier.isSafePathComponent(name) && !names.contains(name) {
            names.append(name)
        }

        var candidates: [URL] = []
        /// Appends `<Library>/<relative>/<name>` when it resolves to a direct
        /// child of `<Library>/<relative>`.
        func add(_ relative: String, _ name: String) {
            guard BundleIdentifier.isSafePathComponent(name) else { return }
            let parent = library.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
            let candidate = parent.appendingPathComponent(name).standardizedFileURL
            guard candidate.deletingLastPathComponent().standardizedFileURL.path == parent.path,
                  candidate.lastPathComponent == name else { return }
            candidates.append(candidate)
        }

        add("Application Support", bundleID)
        for name in names { add("Application Support", name) }
        add("Caches", bundleID)
        add("Preferences", "\(bundleID).plist")
        add("Containers", bundleID)
        candidates += matchingChildren(of: library.appendingPathComponent("Group Containers", isDirectory: true)) { name in
            // The full bundle id, never just its last two components:
            // `vendor.app` also names other vendors' and shared containers.
            BundleIdentifier.name(name, containsComponents: bundleID)
        }
        add("Saved Application State", "\(bundleID).savedState")
        candidates += matchingChildren(of: library.appendingPathComponent("LaunchAgents", isDirectory: true)) { name in
            // `<bundle id>.plist` or `<bundle id>.<anything>.plist`. A bare
            // prefix test would hand `com.vendor.app2.*` to `com.vendor.app`.
            let lower = name.lowercased()
            guard lower.hasSuffix(".plist") else { return false }
            let stem = String(lower.dropLast(".plist".count))
            let id = bundleID.lowercased()
            return stem == id || stem.hasPrefix(id + ".")
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

    /// Direct children of `directory` whose name satisfies `predicate`.
    private func matchingChildren(of directory: URL, _ predicate: (String) -> Bool) -> [URL] {
        let parent = directory.standardizedFileURL.path
        return fileSystem.readableChildren(of: directory).filter {
            $0.standardizedFileURL.deletingLastPathComponent().path == parent && predicate($0.lastPathComponent)
        }
    }
}
