import Foundation
import HelperProtocol
import Observation
import ServiceManagement

/// Errors raised by `HelperClient` itself. Validation failures surface as
/// `HelperValidationError`; transport failures as the `NSXPCConnection` error.
public enum HelperClientError: Error, LocalizedError, Sendable {
    case proxyUnavailable
    case timedOut
    case emptyReply
    case versionMismatch(helper: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable: return "The helper connection could not be established."
        case .timedOut: return "The helper did not respond in time."
        case .emptyReply: return "The helper returned an empty reply."
        case .versionMismatch(let helper, let expected):
            return "Helper protocol version \(helper) does not match the app's \(expected); reinstall the helper."
        }
    }
}

/// App side of the privileged helper (CONTRACTS.md, "M3 — App side of the helper").
///
/// Every operation is validated locally with the same `HelperRequestValidator`
/// the helper uses, so a bad request never leaves the process. The XPC
/// connection is created lazily, pinned to `HelperConstants.helperRequirement`
/// so we only ever talk to our own signed helper, and dropped on interruption,
/// invalidation or any transport error so the next call reconnects.
@MainActor
@Observable
public final class HelperClient {
    public static let shared = HelperClient()

    /// True after `checkAvailability()` reached a helper speaking our protocol version.
    public private(set) var isAvailable = false
    /// Version string the helper reported on the last successful check.
    public private(set) var helperVersion: String?
    /// Human-readable description of the last failure, for Settings and onboarding.
    public private(set) var lastError: String?

    /// Registration state is delegated to the onboarding installer so exactly
    /// one type talks to `SMAppService`.
    let installer: HelperInstaller

    public var installStatus: SMAppService.Status { installer.status }
    public var installStatusLabel: String { installer.statusLabel }
    public var isInstalled: Bool { installer.isInstalled }

    private let validator = HelperRequestValidator(isSymlink: HelperRequestValidator.fileManagerSymlinkCheck)
    private var connection: NSXPCConnection?

    private static let availabilityTimeout: Duration = .seconds(3)

    init(installer: HelperInstaller = HelperInstaller()) {
        self.installer = installer
    }

    // MARK: - Installation (delegated to HelperInstaller)

    public func refreshInstallStatus() {
        installer.refresh()
    }

    public func install() {
        installer.install()
        lastError = installer.lastError
    }

    public func uninstall() async {
        await installer.uninstall()
        lastError = installer.lastError
        dropConnection()
        isAvailable = false
        helperVersion = nil
    }

    public static func openLoginItemsSettings() {
        HelperInstaller.openLoginItemsSettings()
    }

    // MARK: - Operations

    /// Validates locally, then performs `operation` over XPC. Throws
    /// `HelperValidationError` before any XPC traffic when the request is invalid.
    public func perform(_ operation: HelperOperation) async throws -> HelperResponse {
        let request = HelperRequest(operation: operation, callerHome: Self.callerHome())
        try validator.validate(request)
        let payload = try HelperJSON.encode(request)

        let replyData: Data = try await send { helper, continuation in
            helper.perform(payload) { data in
                continuation.resume(returning: data)
            }
        }
        guard !replyData.isEmpty else { throw HelperClientError.emptyReply }
        let response = try HelperJSON.decode(HelperResponse.self, from: replyData)
        if !response.succeeded {
            lastError = response.message
        }
        return response
    }

    /// Asks the helper for its protocol version with a 3-second budget and
    /// updates `isAvailable`. A version mismatch counts as unavailable.
    public func checkAvailability() async {
        installer.refresh()
        do {
            let version = try await fetchVersionWithTimeout()
            helperVersion = version
            guard version == HelperConstants.version else {
                throw HelperClientError.versionMismatch(helper: version, expected: HelperConstants.version)
            }
            isAvailable = true
            lastError = nil
        } catch {
            isAvailable = false
            lastError = error.localizedDescription
            dropConnection()
        }
    }

    // MARK: - Transport

    /// Performs one remote call. The proxy is created per call so its error
    /// handler resumes *this* continuation; NSXPC guarantees that exactly one
    /// of the reply block or the error handler runs.
    private func send<T: Sendable>(
        _ invoke: (any HelperXPCProtocol, CheckedContinuation<T, any Error>) -> Void
    ) async throws -> T {
        let connection = activeConnection()
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    continuation.resume(throwing: error)
                }
                guard let helper = proxy as? any HelperXPCProtocol else {
                    continuation.resume(throwing: HelperClientError.proxyUnavailable)
                    return
                }
                invoke(helper, continuation)
            }
        } catch {
            isAvailable = false
            lastError = error.localizedDescription
            dropConnection()
            throw error
        }
    }

    private func fetchVersion() async throws -> String {
        try await send { helper, continuation in
            helper.version { version in
                continuation.resume(returning: version)
            }
        }
    }

    private func fetchVersionWithTimeout() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.fetchVersion() }
            group.addTask {
                try await Task.sleep(for: Self.availabilityTimeout)
                throw HelperClientError.timedOut
            }
            do {
                guard let first = try await group.next() else { throw HelperClientError.timedOut }
                group.cancelAll()
                return first
            } catch {
                // Invalidating the connection makes NSXPC fire the error handler
                // of the in-flight call, so the other child task finishes too.
                dropConnection()
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Connection management

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        self.connection = connection
        return connection
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any HelperXPCProtocol).self)
        // Only our own Developer ID-signed helper may answer (macOS 13+ API;
        // the deployment target is 26).
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        let onLoss: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.dropConnection()
                self?.isAvailable = false
            }
        }
        connection.interruptionHandler = onLoss
        connection.invalidationHandler = onLoss
        connection.resume()
        return connection
    }

    private func dropConnection() {
        guard let connection else { return }
        self.connection = nil
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
    }

    private static func callerHome() -> String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }
}
