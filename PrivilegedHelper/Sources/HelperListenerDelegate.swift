@preconcurrency import Foundation
import HelperProtocol
import Security
import os

/// Accepts a connection only from a process that satisfies
/// `HelperConstants.clientRequirement` (our Team ID and bundle identifier,
/// Developer ID chain). The check runs on the peer's audit token, which cannot
/// be spoofed or reused the way a PID can, before any method is exported.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "listener")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        switch verifyPeer(of: newConnection) {
        case .success:
            logger.notice("Accepted connection from pid \(pid, privacy: .public)")
        case .failure(let error):
            logger.error("Rejected connection from pid \(pid, privacy: .public): \(error.description, privacy: .public)")
            return false
        }

        // Belt and braces: the system re-checks the same requirement on every
        // message for the lifetime of the connection (macOS 13+).
        newConnection.setCodeSigningRequirement(HelperConstants.clientRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.invalidationHandler = { [logger] in
            logger.notice("Connection from pid \(pid, privacy: .public) invalidated")
        }
        newConnection.resume()
        return true
    }

    // MARK: - Code-signing verification

    enum PeerError: Error, CustomStringConvertible {
        case noAuditToken
        case requirementSyntax(OSStatus)
        case guestLookup(OSStatus)
        case requirementNotSatisfied(OSStatus)

        var description: String {
            switch self {
            case .noAuditToken: return "could not read peer audit token"
            case .requirementSyntax(let status): return "client requirement failed to parse (OSStatus \(status))"
            case .guestLookup(let status): return "SecCodeCopyGuestWithAttributes failed (OSStatus \(status))"
            case .requirementNotSatisfied(let status): return "peer does not satisfy client requirement (OSStatus \(status))"
            }
        }
    }

    private func verifyPeer(of connection: NSXPCConnection) -> Result<Void, PeerError> {
        guard let token = Self.auditToken(of: connection) else {
            return .failure(.noAuditToken)
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(HelperConstants.clientRequirement as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            return .failure(.requirementSyntax(reqStatus))
        }

        let attributes: [CFString: Any] = [kSecGuestAttributeAudit: token as NSData]
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return .failure(.guestLookup(guestStatus))
        }

        let validity = SecCodeCheckValidity(code, [], requirement)
        guard validity == errSecSuccess else {
            return .failure(.requirementNotSatisfied(validity))
        }
        return .success(())
    }

    /// The peer's `audit_token_t` as raw bytes. `NSXPCConnection` exposes it
    /// only through KVC; if that ever stops working we fail closed (the
    /// per-message `setCodeSigningRequirement` is not a substitute for the
    /// accept-time check, so we do not fall back to the PID).
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        guard let value = connection.value(forKey: "auditToken") as? Data,
              value.count == MemoryLayout<audit_token_t>.size
        else { return nil }
        return value
    }
}
