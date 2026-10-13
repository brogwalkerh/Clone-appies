import Foundation

/// Refuses to remove anything under ProtectedPaths; wraps another Remover.
///
/// The protected check runs over the whole batch before anything is touched:
/// if any finding is protected, `RemovalError.protectedPath` is thrown and the
/// wrapped remover is never called.
public struct GuardedRemover: Remover {
    private let wrapped: any Remover
    private let protectedPaths: ProtectedPaths

    public init(wrapping: any Remover, protectedPaths: ProtectedPaths) {
        self.wrapped = wrapping
        self.protectedPaths = protectedPaths
    }

    public func remove(_ findings: [Finding], mode: RemovalMode,
                       progress: (@Sendable (Int, Int) -> Void)?) async throws -> RemovalManifest {
        for finding in findings where protectedPaths.isProtected(finding.path) {
            throw RemovalError.protectedPath(finding.path)
        }
        return try await wrapped.remove(findings, mode: mode, progress: progress)
    }

    public func undo(_ manifest: RemovalManifest) async throws -> [RemovalRecord] {
        try await wrapped.undo(manifest)
    }
}
