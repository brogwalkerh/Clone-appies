import Foundation

/// One request to the helper. Serialized as JSON on the XPC wire.
public struct HelperRequest: Codable, Sendable, Hashable {
    public let id: UUID
    public let operation: HelperOperation
    /// Home directory of the calling user. Validated: absolute, no "..",
    /// under `/Users/` or exactly `/var/root`. Only `speedUpMail` uses it.
    public let callerHome: String

    public init(operation: HelperOperation, callerHome: String) {
        self.init(id: UUID(), operation: operation, callerHome: callerHome)
    }

    public init(id: UUID, operation: HelperOperation, callerHome: String) {
        self.id = id
        self.operation = operation
        self.callerHome = callerHome
    }
}

/// The helper's reply to one `HelperRequest`.
public struct HelperResponse: Codable, Sendable, Hashable {
    /// Returned when the helper could not even decode the request.
    public static let unparseableRequestID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public let requestID: UUID
    public let succeeded: Bool
    public let message: String
    public let bytesReclaimed: Int64?
    public let durationSeconds: Double

    public init(requestID: UUID, succeeded: Bool, message: String, bytesReclaimed: Int64?, durationSeconds: Double) {
        self.requestID = requestID
        self.succeeded = succeeded
        self.message = message
        self.bytesReclaimed = bytesReclaimed
        self.durationSeconds = durationSeconds
    }
}

/// JSON encoding shared by both ends of the wire. Keys are sorted so payloads
/// are deterministic and diffable in logs.
public enum HelperJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
