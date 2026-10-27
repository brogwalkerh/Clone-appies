import Darwin
import Foundation

/// The `com.apple.quarantine` extended attribute Gatekeeper stamps on
/// downloads: `flags;timestamp;agent;identifier` with hexadecimal flags and
/// a hexadecimal Unix timestamp. Some agents append or substitute extra
/// fields (an origin URL, an empty identifier); parsing is tolerant of that.
///
/// Parsing is pure and tested; `read(path:)` is the `getxattr` wrapper.
struct QuarantineAttribute: Sendable, Hashable {
    static let name = "com.apple.quarantine"
    /// Upper bound for a sane attribute; anything larger is ignored.
    static let maxBytes = 4096

    let flags: UInt32
    let date: Date?
    /// Human-readable downloading application ("Safari", "Google Chrome").
    let agentName: String?
    /// Fourth field: LSQuarantine event identifier (a UUID) when present.
    let identifier: String?
    /// Origin URL when the agent put one in the attribute itself.
    let originURL: URL?

    /// Parses the attribute string. Returns nil unless the first field is a
    /// hexadecimal flags word; everything after that is optional.
    static func parse(_ raw: String) -> QuarantineAttribute? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, let flags = UInt32(first, radix: 16) else { return nil }

        var date: Date?
        if fields.count > 1, let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(seconds))
        }

        var agent: String?
        if fields.count > 2, !fields[2].isEmpty, !looksLikeURL(fields[2]) {
            agent = fields[2]
        }

        var identifier: String?
        if fields.count > 3, !fields[3].isEmpty, !looksLikeURL(fields[3]) {
            identifier = fields[3]
        }

        let origin = fields.dropFirst(2).first(where: looksLikeURL).flatMap { URL(string: $0) }
        return QuarantineAttribute(flags: flags, date: date, agentName: agent, identifier: identifier, originURL: origin)
    }

    /// `"Downloaded from Safari"`, `"Downloaded from Safari (example.com)"`, or
    /// nil when neither an agent nor a host is known.
    var downloadDescription: String? {
        let host = originURL?.host()
        switch (agentName, host) {
        case let (agent?, host?): return "Downloaded from \(agent) (\(host))"
        case let (agent?, nil): return "Downloaded from \(agent)"
        case let (nil, host?): return "Downloaded from \(host)"
        case (nil, nil): return nil
        }
    }

    private static func looksLikeURL(_ field: String) -> Bool {
        field.range(of: "://") != nil
    }

    // MARK: getxattr

    /// Reads and parses the attribute, or nil when it is absent, unreadable or
    /// malformed. Does not follow symlinks.
    static func read(path: String) -> QuarantineAttribute? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= maxBytes else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            getxattr(path, name, raw.baseAddress, raw.count, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return nil }
        let text = String(decoding: buffer.prefix(read), as: UTF8.self)
        return parse(text)
    }
}
