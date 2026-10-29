import ArgumentParser
import Foundation
import CleanerCore
import SmartCareModule

struct ActivityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity",
        abstract: "Show My Activity: space reclaimed, threats quarantined and recent events.")

    @Option(name: .long, help: "Number of weekly buckets to show.")
    var weeks = 8

    @Option(name: .long, help: "Number of recent events to list.")
    var limit = 10

    @Flag(name: .long, help: "Print a JSON document instead of text.")
    var json = false

    @OptionGroup var history: HistoryOptions

    func validate() throws {
        guard weeks >= 1, weeks <= 104 else { throw ValidationError("--weeks must be between 1 and 104.") }
        guard limit >= 0 else { throw ValidationError("--limit cannot be negative.") }
    }

    func run() async throws {
        let events = try await history.storage.activity.events(since: nil)
        try ActivityReport.write(events: events, now: .now, calendar: .current, weeks: weeks, limit: limit,
                                 json: json, io: .standard)
    }
}

/// JSON shape of `activity --json`.
struct ActivityDocument: Codable, Hashable, Sendable {
    struct Week: Codable, Hashable, Sendable {
        let start: Date
        let bytes: [String: Int64]
    }
    let bytesReclaimed: Int64
    let bytesReclaimedLast30Days: Int64
    let itemsRemoved: Int
    let threatsQuarantined: Int
    let maintenanceRuns: Int
    let estimatedTimeSavedSeconds: TimeInterval
    let weeks: [Week]
    let recent: [ActivityEvent]
}

enum ActivityReport {
    static func write(events: [ActivityEvent], now: Date, calendar: Calendar, weeks: Int, limit: Int,
                      json: Bool, io: CommandIO) throws {
        let stats = ActivityStats(events: events, now: now, calendar: calendar, weeks: weeks)
        let recent = Array(events.suffix(limit).reversed())
        if json {
            let document = ActivityDocument(
                bytesReclaimed: stats.bytesReclaimed,
                bytesReclaimedLast30Days: stats.bytesReclaimedLast30Days,
                itemsRemoved: stats.itemsRemoved,
                threatsQuarantined: stats.threatsQuarantined,
                maintenanceRuns: stats.maintenanceRuns,
                estimatedTimeSavedSeconds: stats.estimatedTimeSaved,
                weeks: stats.weeks.map { week in
                    ActivityDocument.Week(start: week.start,
                                          bytes: Dictionary(uniqueKeysWithValues: week.bytesByModule.map { ($0.key.rawValue, $0.value) }))
                },
                recent: recent)
            io.out.write(try ScanJSON.encode(document))
            return
        }
        guard !events.isEmpty else {
            io.out.write("No activity yet. Run `maccleaner smart-care` to start.")
            return
        }
        io.out.write("Reclaimed: \(ByteFormatter.string(stats.bytesReclaimed)) (\(ByteFormatter.string(stats.bytesReclaimedLast30Days)) in the last 30 days)")
        io.out.write("Items removed: \(stats.itemsRemoved)   Threats quarantined: \(stats.threatsQuarantined)   Maintenance runs: \(stats.maintenanceRuns)")
        io.out.write("Time saved: about \(duration(stats.estimatedTimeSaved))")
        io.out.write("Per week:")
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for week in stats.weeks {
            io.out.write("  \(formatter.string(from: week.start))  \(ByteFormatter.string(week.totalBytes))")
        }
        io.out.write("Recent:")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for event in recent {
            let bytes = event.bytes > 0 ? "  \(ByteFormatter.string(event.bytes))" : ""
            io.out.write("  \(formatter.string(from: event.date))  \(event.title)\(bytes)")
        }
    }

    /// "3 h 20 min", "45 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }
}
