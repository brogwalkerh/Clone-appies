import Foundation

/// Services tracked by the permissions review. The reader is platform-specific
/// (UIKitBridge reads TCC.db); this module only holds the model and the
/// `kTCCService*` mapping so the bridge and tests share it.
public enum PrivacyService: String, Codable, Sendable, CaseIterable {
    case camera, microphone, fullDiskAccess, accessibility, screenRecording, location,
         contacts, calendars, photos, inputMonitoring, automation

    public var displayName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .location: "Location"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .photos: "Photos"
        case .inputMonitoring: "Input Monitoring"
        case .automation: "Automation"
        }
    }

    /// Maps a TCC service name (`kTCCServiceCamera`, with or without the
    /// prefix, any case) to a service; nil for services we do not surface.
    public static func mapTCCService(_ raw: String) -> PrivacyService? {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("ktccservice") { key = String(key.dropFirst("ktccservice".count)) }
        return tccNames[key]
    }

    private static let tccNames: [String: PrivacyService] = [
        "camera": .camera,
        "microphone": .microphone,
        "systempolicyallfiles": .fullDiskAccess,
        "accessibility": .accessibility,
        "screencapture": .screenRecording,
        "location": .location,
        "locationservices": .location,
        "addressbook": .contacts,
        "contactsfull": .contacts,
        "contactslimited": .contacts,
        "calendar": .calendars,
        "photos": .photos,
        "photosadd": .photos,
        "listenevent": .inputMonitoring,
        "postevent": .inputMonitoring,
        "appleevents": .automation,
    ]
}

public struct PermissionGrant: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(service.rawValue):\(clientID)" }
    public let service: PrivacyService
    public let clientID: String
    public let clientName: String?
    public let granted: Bool
    public let lastModified: Date?

    public init(service: PrivacyService, clientID: String, clientName: String?, granted: Bool,
                lastModified: Date?) {
        self.service = service
        self.clientID = clientID
        self.clientName = clientName
        self.granted = granted
        self.lastModified = lastModified
    }
}

public protocol PermissionsReader: Sendable {
    func grants() async throws -> [PermissionGrant]
}
