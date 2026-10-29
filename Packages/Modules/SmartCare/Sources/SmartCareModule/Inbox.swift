import Foundation

/// A whole-file JSON document written atomically (ADR 0007).
public struct JSONFileRecord<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `nil` when the file is missing or does not decode.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
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
    /// A `maccleaner://` URL the message opens.
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

    /// A failed write keeps the in-memory answer; the next call re-reads the file.
    private func write(_ messages: [InboxMessage]) -> [InboxMessage] {
        try? record.save(messages)
        return messages
    }
}
