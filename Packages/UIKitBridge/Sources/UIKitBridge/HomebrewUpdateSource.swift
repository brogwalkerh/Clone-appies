import Foundation
import ApplicationsModule

/// `UpdateSource` for Homebrew casks: runs `brew outdated --cask --json=v2`
/// and matches each outdated cask token to an installed app discovered with
/// `source == .homebrewCask`. Returns `[]` whenever `brew` is missing, exits
/// non-zero, or prints something we cannot decode; the Updater must never fail
/// because Homebrew is unhappy.
public struct HomebrewUpdateSource: UpdateSource {
    /// Where `brew` lives on Apple Silicon and Intel installs, in preference order.
    public static let defaultBrewLocations: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
        URL(fileURLWithPath: "/usr/local/bin/brew"),
    ]

    private let brewCandidates: [URL]

    public init(brewCandidates: [URL] = HomebrewUpdateSource.defaultBrewLocations) {
        self.brewCandidates = brewCandidates
    }

    public func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        let caskApps = apps.filter { $0.source == .homebrewCask }
        guard !caskApps.isEmpty, let brew = brewExecutable() else { return [] }

        let output: Data
        do {
            output = try await HomebrewUpdateSource.run(brew, arguments: ["outdated", "--cask", "--json=v2"])
        } catch {
            return []
        }
        guard let response = try? JSONDecoder().decode(OutdatedResponse.self, from: output) else {
            return []
        }
        return HomebrewUpdateSource.match(casks: response.casks, to: caskApps)
    }

    // MARK: Matching

    /// Pairs outdated casks with installed apps by normalized name. Exposed for tests.
    static func match(casks: [OutdatedCask], to apps: [InstalledApp]) -> [AvailableUpdate] {
        var updates: [AvailableUpdate] = []
        var claimed: Set<URL> = []
        for cask in casks {
            guard let latest = cask.currentVersion, !latest.isEmpty else { continue }
            let token = normalize(cask.name)
            guard !token.isEmpty,
                  let app = apps.first(where: { !claimed.contains($0.bundleURL) && matches(token: token, app: $0) })
            else { continue }
            claimed.insert(app.bundleURL)
            if let installed = app.version,
               VersionComparator.compare(installed, latest) != .orderedAscending {
                // brew says outdated but the bundle already carries the newer
                // version (e.g. the app auto-updated itself); trust the bundle.
                continue
            }
            updates.append(AvailableUpdate(app: app,
                                           latestVersion: latest,
                                           downloadURL: nil,
                                           releaseNotesURL: URL(string: "https://formulae.brew.sh/cask/\(cask.name)"),
                                           source: .homebrewCask))
        }
        return updates
    }

    /// Lowercases and strips spaces and dashes so "visual-studio-code" matches
    /// "Visual Studio Code" and "Visual Studio Code.app".
    static func normalize(_ string: String) -> String {
        String(string.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" })
    }

    private static func matches(token: String, app: InstalledApp) -> Bool {
        let candidates = [normalize(app.name), normalize(app.bundleURL.deletingPathExtension().lastPathComponent)]
        for candidate in candidates where !candidate.isEmpty {
            if candidate == token { return true }
            // Allow a token that is a prefix of the app name ("firefox" vs
            // "firefoxdeveloperedition" is rejected by the length guard below).
            let shorter = min(candidate.count, token.count)
            if shorter >= 5, candidate.hasPrefix(token) || token.hasPrefix(candidate) {
                return abs(candidate.count - token.count) <= 3
            }
        }
        return false
    }

    // MARK: Process plumbing

    private func brewExecutable() -> URL? {
        brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    enum BrewError: Error, Sendable {
        case exitStatus(Int32)
    }

    /// Runs `brew` through the shared `ProcessRunner` with the Homebrew
    /// environment knobs that keep it quiet and fast.
    static func run(_ executable: URL, arguments: [String]) async throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        let output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment)
        guard output.exitStatus == 0 else { throw BrewError.exitStatus(output.exitStatus) }
        return output.stdout
    }

    // MARK: JSON

    struct OutdatedResponse: Decodable, Sendable {
        var casks: [OutdatedCask]

        private enum CodingKeys: String, CodingKey { case casks }

        init(casks: [OutdatedCask]) {
            self.casks = casks
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            casks = try container.decodeIfPresent([OutdatedCask].self, forKey: .casks) ?? []
        }
    }

    struct OutdatedCask: Decodable, Sendable {
        var name: String
        var installedVersions: [String]
        var currentVersion: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }

        init(name: String, installedVersions: [String], currentVersion: String?) {
            self.name = name
            self.installedVersions = installedVersions
            self.currentVersion = currentVersion
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            installedVersions = try container.decodeIfPresent([String].self, forKey: .installedVersions) ?? []
            currentVersion = try container.decodeIfPresent(String.self, forKey: .currentVersion)
        }
    }
}
