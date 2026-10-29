import Foundation

/// File layout shared by the app, the MenuAgent and the CLI (ADR 0007). All
/// files live in one directory, normally
/// `~/Library/Application Support/com.example.maccleaner`.
public struct SmartCareStorage: Sendable {
    public let directory: URL
    public let activity: JSONLinesActivityStore
    public let inbox: InboxStore
    public let schedules: JSONFileRecord<[ScanSchedule]>
    /// Schedule id -> last time it ran.
    public let scheduleRuns: JSONFileRecord<[UUID: Date]>
    public let actionSets: JSONFileRecord<[ActionSet]>
    /// Assistant rule id -> when it was dismissed.
    public let dismissedRecommendations: JSONFileRecord<[String: Date]>

    public init(directory: URL) {
        self.directory = directory
        activity = JSONLinesActivityStore(fileURL: directory.appendingPathComponent("activity.jsonl"))
        inbox = InboxStore(fileURL: directory.appendingPathComponent("inbox.json"))
        schedules = JSONFileRecord(fileURL: directory.appendingPathComponent("schedules.json"))
        scheduleRuns = JSONFileRecord(fileURL: directory.appendingPathComponent("schedule-runs.json"))
        actionSets = JSONFileRecord(fileURL: directory.appendingPathComponent("action-sets.json"))
        dismissedRecommendations = JSONFileRecord(fileURL: directory.appendingPathComponent("assistant-dismissed.json"))
    }

    /// `~/Library/Application Support/com.example.maccleaner` for `home`.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/com.example.maccleaner", isDirectory: true)
    }
}
