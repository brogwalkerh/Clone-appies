import Foundation

public enum JSONFileRecordError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The file exists but could not be read or does not decode as the
    /// expected value (damaged, or written by a newer version).
    case undecodable(URL, reason: String)

    public var description: String {
        switch self {
        case .undecodable(let url, let reason):
            return "\(url.path) could not be read as the expected document: \(reason)"
        }
    }
}

/// A whole-file JSON document written atomically (ADR 0007).
///
/// The files are shared by the app, the MenuAgent and the CLI, possibly of
/// different versions. A file one of them cannot decode is never overwritten:
/// `save` first moves it aside to `<name>.corrupt-<UTC timestamp>`.
public struct JSONFileRecord<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `nil` when the file is missing or does not decode. Use `read()` to
    /// tell the two apart.
    public func load() -> Value? {
        (try? read()) ?? nil
    }

    /// `nil` when the file is missing; throws `JSONFileRecordError.undecodable`
    /// when it exists but cannot be read or decoded.
    public func read() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Value.self, from: data)
        } catch {
            // Deleted between the check and the read: missing, not damaged.
            if !FileManager.default.fileExists(atPath: fileURL.path) { return nil }
            throw JSONFileRecordError.undecodable(fileURL, reason: "\(error)")
        }
    }

    /// Atomic; creates the parent directory. An existing file that does not
    /// decode is kept as `<name>.corrupt-<timestamp>` rather than replaced; if
    /// it cannot be moved aside the save fails and the file is left alone.
    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try preserveUndecodableFile()
        try data.write(to: fileURL, options: .atomic)
    }

    /// Where an undecodable file was moved, or nil when there was none.
    @discardableResult
    func preserveUndecodableFile(now: Date = .now) throws -> URL? {
        do {
            _ = try read()
            return nil
        } catch is JSONFileRecordError {
            let fm = FileManager.default
            let base = fileURL.lastPathComponent + ".corrupt-" + Self.timestamp(now)
            let directory = fileURL.deletingLastPathComponent()
            var destination = directory.appendingPathComponent(base, isDirectory: false)
            var attempt = 1
            while fm.fileExists(atPath: destination.path) {
                attempt += 1
                destination = directory.appendingPathComponent("\(base)-\(attempt)", isDirectory: false)
            }
            try fm.moveItem(at: fileURL, to: destination)
            return destination
        }
    }

    /// `yyyyMMdd-HHmmss` in UTC.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "-" + pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2)
    }
}

public enum InboxKind: String, Codable, Sendable {
    case info, scanResult, reminder, threat, update
}

/// A Notification Center message (the toolbar bell, PLAN.md §3.12).
public struct InboxMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let kind: InboxKind
    public let title: String
    public let body: String
    public var isRead: Bool
    /// A `featherduster://` URL the message opens.
    public let link: String?

    public init(id: UUID = UUID(), date: Date = .now, kind: InboxKind = .info, title: String, body: String,
                isRead: Bool = false, link: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.body = body
        self.isRead = isRead
        self.link = link
    }
}

/// Shared by the app and the MenuAgent: every call re-reads the file, so each
/// process sees the other's messages. Newest first, capped at `capacity`.
public actor InboxStore {
    private let record: JSONFileRecord<[InboxMessage]>
    private let capacity: Int

    public init(fileURL: URL, capacity: Int = 50) {
        record = JSONFileRecord(fileURL: fileURL)
        self.capacity = max(1, capacity)
    }

    public func messages() -> [InboxMessage] {
        (record.load() ?? []).sorted { $0.date > $1.date }
    }

    @discardableResult
    public func post(_ message: InboxMessage) -> [InboxMessage] {
        var all = messages().filter { $0.id != message.id }
        all.insert(message, at: 0)
        all.sort { $0.date > $1.date }
        return write(Array(all.prefix(capacity)))
    }

    /// Marks one message read, or all of them when `id` is nil.
    @discardableResult
    public func markRead(_ id: UUID?) -> [InboxMessage] {
        var all = messages()
        for index in all.indices where id == nil || all[index].id == id {
            all[index].isRead = true
        }
        return write(all)
    }

    @discardableResult
    public func removeAll() -> [InboxMessage] {
        write([])
    }

    /// A failed write keeps the in-memory answer; the next call re-reads the
    /// file. An inbox file this version cannot decode reads as empty and is
    /// moved aside by `JSONFileRecord.save`, never overwritten.
    private func write(_ messages: [InboxMessage]) -> [InboxMessage] {
        try? record.save(messages)
        return messages
    }
}
