import Foundation
import CleanerCore

/// Turns a `ScanScope` into the list of roots the malware scanner walks.
/// Roots may be files (running executables, launchd programs) or directories.
/// Only existing, non-symlink paths are returned; roots nested inside another
/// root are dropped so no file is visited twice.
public struct ScanScopeResolver: Sendable {
    public static let recentAppWindow: TimeInterval = 7 * 86_400

    private let fileSystem: any FileSystem
    private let runningProcesses: (any RunningProcessPathsProvider)?
    private let protectedPaths: ProtectedPaths

    public init(fileSystem: any FileSystem, runningProcesses: (any RunningProcessPathsProvider)? = nil) {
        self.init(fileSystem: fileSystem, runningProcesses: runningProcesses, protectedPaths: .default)
    }

    /// Additional initializer with an explicit protected-path set (deep scans
    /// skip protected volumes).
    public init(fileSystem: any FileSystem, runningProcesses: (any RunningProcessPathsProvider)?,
                protectedPaths: ProtectedPaths) {
        self.fileSystem = fileSystem
        self.runningProcesses = runningProcesses
        self.protectedPaths = protectedPaths
    }

    /// quick: running executables, ~/Library/LaunchAgents, /Library/LaunchAgents,
    ///        /Library/LaunchDaemons and the programs they reference, ~/Downloads,
    ///        ~/Desktop, apps modified in the last 7 days.
    /// normal: quick + home + /Applications + /usr/local.
    /// deep: normal + every mounted volume under /Volumes except protected /
    ///       Time Machine ones.
    public func roots(for scope: ScanScope, home: URL, now: Date) async -> [URL] {
        let home = home.standardizedFileURL
        let userAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let systemAgents = URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        let systemDaemons = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true)

        var candidates: [URL] = []
        if let runningProcesses {
            candidates += await runningProcesses.executablePaths()
        }
        candidates += [userAgents, systemAgents, systemDaemons]
        candidates += launchdPrograms(in: [userAgents, systemAgents, systemDaemons])
        candidates += [home.appendingPathComponent("Downloads", isDirectory: true),
                       home.appendingPathComponent("Desktop", isDirectory: true)]
        candidates += recentApps(in: [applications, userApplications], now: now)

        if scope.includes(.normal) {
            candidates += [home, applications, systemAgents, systemDaemons,
                           URL(fileURLWithPath: "/usr/local", isDirectory: true)]
        }
        if scope.includes(.deep) {
            candidates += volumes()
        }
        return Self.deduplicated(candidates.filter(isUsable))
    }

    // MARK: - Implementation

    private func isUsable(_ url: URL) -> Bool {
        guard fileSystem.exists(url), let attributes = try? fileSystem.attributes(of: url) else { return false }
        return !attributes.isSymlink && !protectedPaths.isProtected(url)
    }

    /// Programs referenced by the plists in `directories`, when absolute and present.
    private func launchdPrograms(in directories: [URL]) -> [URL] {
        var programs: [URL] = []
        for directory in directories where fileSystem.exists(directory) {
            guard let children = try? fileSystem.children(of: directory) else { continue }
            for plist in children where plist.pathExtension.lowercased() == "plist" {
                guard let data = try? fileSystem.contents(of: plist),
                      let info = LaunchAgentInfo.parse(data),
                      let executable = info.executable, executable.hasPrefix("/") else { continue }
                programs.append(URL(fileURLWithPath: executable))
            }
        }
        return programs
    }

    /// `.app` bundles in `directories` modified within `recentAppWindow`.
    private func recentApps(in directories: [URL], now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-Self.recentAppWindow)
        var apps: [URL] = []
        for directory in directories where fileSystem.exists(directory) {
            guard let children = try? fileSystem.children(of: directory) else { continue }
            for child in children where child.pathExtension.lowercased() == "app" {
                guard let attributes = try? fileSystem.attributes(of: child), attributes.isDirectory,
                      let modified = attributes.modifiedAt, modified >= cutoff else { continue }
                apps.append(child)
            }
        }
        return apps
    }

    /// Mounted volumes, minus symlinks (the boot volume alias), hidden
    /// entries and backup bundles.
    private func volumes() -> [URL] {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard fileSystem.exists(root), let children = try? fileSystem.children(of: root) else { return [] }
        return children.filter { volume in
            let name = volume.lastPathComponent
            if name.hasPrefix(".") { return false }
            if ["backupbundle", "sparsebundle", "timemachine"].contains(volume.pathExtension.lowercased()) { return false }
            guard let attributes = try? fileSystem.attributes(of: volume) else { return false }
            return attributes.isDirectory && !attributes.isSymlink
        }
    }

    /// Sorted, unique roots with anything nested under another root removed.
    static func deduplicated(_ urls: [URL]) -> [URL] {
        var kept: [URL] = []
        for url in urls.map(\.standardizedFileURL).sorted(by: { $0.path < $1.path }) {
            if kept.contains(where: { PathHelpers.isDescendant(url, of: $0) }) { continue }
            kept.append(url)
        }
        return kept
    }
}
