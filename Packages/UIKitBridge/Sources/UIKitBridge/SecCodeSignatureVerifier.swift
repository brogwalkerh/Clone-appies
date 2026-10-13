import Foundation
import ProtectionModule
import Security

/// `CodeSignatureVerifier` backed by Security.framework.
///
/// `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity(code, [], nil)`:
/// - `errSecSuccess` → `true`
/// - a signature problem (unsigned, broken seal, bad resource) → `false`
/// - anything else (file missing, not code, I/O) → `nil`, "unknown"
///
/// Verification is a few milliseconds of disk I/O and crypto per bundle, so it
/// always runs on a detached utility task, never on the caller's actor, and
/// results are cached per path for the process lifetime (bounded, see
/// `SignatureVerdictCache`). The cache is keyed by the exact path string; a
/// replaced binary at the same path keeps the old verdict until relaunch, which
/// is acceptable for the Protection Monitor's "is this persistence item signed"
/// question and avoids re-verifying `/Applications` on every FSEvents burst.
public struct SecCodeSignatureVerifier: CodeSignatureVerifier {
    public init() {}

    public func isValidlySigned(_ executable: URL) async -> Bool? {
        let path = executable.standardizedFileURL.path(percentEncoded: false)
        if let cached = await SignatureVerdictCache.shared.verdict(for: path) {
            return cached.value
        }
        let verdict = await Task.detached(priority: .utility) {
            SecCodeSignatureVerifier.verify(path: path)
        }.value
        await SignatureVerdictCache.shared.store(verdict, for: path)
        return verdict
    }

    // MARK: Security.framework (nonisolated, synchronous)

    static func verify(path: String) -> Bool? {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return classify(createStatus)
        }
        // TODO(macOS27): consider `.checkAllArchitectures` once the 27 SDK's
        // SecCSFlags are confirmed; the contract pins kSecCSDefaultFlags for now.
        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        return classify(validity)
    }

    /// Maps an `OSStatus` to the contract's tri-state (pure, tested).
    static func classify(_ status: OSStatus) -> Bool? {
        if status == errSecSuccess { return true }
        return signatureFailureCodes.contains(status) ? false : nil
    }

    /// Statuses that mean "there is code here and its signature is not good",
    /// as opposed to "we could not look".
    static let signatureFailureCodes: Set<OSStatus> = [
        errSecCSUnsigned,
        errSecCSSignatureFailed,
        errSecCSSignatureInvalid,
        errSecCSSignatureNotVerifiable,
        errSecCSSignatureUnsupported,
        errSecCSBadResource,
        errSecCSResourcesInvalid,
        errSecCSResourcesNotSealed,
        errSecCSResourceDirectoryFailed,
        errSecCSInfoPlistFailed,
        errSecCSBadFrameworkVersion,
        errSecCSBadMainExecutable,
        errSecCSBadNestedCode,
        errSecCSRevokedNotarization,
    ]
}

/// Process-lifetime cache of signature verdicts, bounded to `capacity`
/// entries. Eviction is FIFO in insertion order: when the bound is hit the
/// oldest tenth is dropped in one go so the hot path stays O(1) amortized.
actor SignatureVerdictCache {
    static let shared = SignatureVerdictCache()

    /// Boxed so that an "unknown" (`nil`) verdict is distinguishable from a miss.
    struct Entry: Sendable, Hashable {
        let value: Bool?
    }

    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func verdict(for path: String) -> Entry? {
        entries[path]
    }

    func store(_ verdict: Bool?, for path: String) {
        if entries.updateValue(Entry(value: verdict), forKey: path) != nil {
            return   // refreshed in place; keeps its original slot in the order
        }
        insertionOrder.append(path)
        if entries.count > capacity {
            let dropCount = max(1, capacity / 10)
            for stale in insertionOrder.prefix(dropCount) {
                entries.removeValue(forKey: stale)
            }
            insertionOrder.removeFirst(dropCount)
        }
    }

    func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}
