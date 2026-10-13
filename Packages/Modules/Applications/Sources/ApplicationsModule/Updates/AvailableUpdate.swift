import Foundation
import CleanerCore

/// A newer version of an installed app, as reported by an `UpdateSource`.
public struct AvailableUpdate: Sendable, Hashable, Codable {
    public let app: InstalledApp
    public let latestVersion: String
    public let downloadURL: URL?
    public let releaseNotesURL: URL?
    public let source: AppSource

    public init(app: InstalledApp, latestVersion: String, downloadURL: URL?,
                releaseNotesURL: URL?, source: AppSource) {
        self.app = app
        self.latestVersion = latestVersion
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.source = source
    }
}

/// A place to ask about updates. Implementations never throw: an unreachable
/// feed simply yields no update for that app.
public protocol UpdateSource: Sendable {
    func check(_ apps: [InstalledApp]) async -> [AvailableUpdate]
}
