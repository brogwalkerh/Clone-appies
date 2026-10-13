@preconcurrency import Foundation
import HelperProtocol
import os

/// The exported XPC object. One instance per connection; it holds no state.
/// Every request is validated with the same `HelperRequestValidator` the app
/// used, then executed strictly from `HelperCommandPlan` by `CommandExecutor`.
final class HelperService: NSObject, HelperXPCProtocol, Sendable {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "service")

    /// Operations are serialized process-wide so two connections cannot, for
    /// example, run `purge` and `rm -rf` on the same volume concurrently.
    private static let workQueue = DispatchQueue(label: HelperConstants.machServiceName + ".work", qos: .utility)

    private let validator = HelperRequestValidator(isSymlink: HelperRequestValidator.fileManagerSymlinkCheck)

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.version)
    }

    func perform(_ requestData: Data, reply: @escaping @Sendable (Data) -> Void) {
        Self.workQueue.async { [validator] in
            let response = Self.handle(requestData, validator: validator)
            do {
                reply(try HelperJSON.encode(response))
            } catch {
                // Encoding a HelperResponse cannot realistically fail; reply
                // with an empty payload so the client's continuation resumes.
                Self.logger.fault("Could not encode response: \(error.localizedDescription, privacy: .public)")
                reply(Data())
            }
        }
    }

    private static func handle(_ requestData: Data, validator: HelperRequestValidator) -> HelperResponse {
        let request: HelperRequest
        do {
            request = try HelperJSON.decode(HelperRequest.self, from: requestData)
        } catch {
            logger.error("Rejected undecodable request: \(error.localizedDescription, privacy: .public)")
            return HelperResponse(requestID: HelperResponse.unparseableRequestID, succeeded: false,
                                  message: "Malformed request", bytesReclaimed: nil, durationSeconds: 0)
        }

        let op = request.operation.name
        let id = request.id.uuidString
        do {
            try validator.validate(request)
        } catch let error as HelperValidationError {
            logger.error("[\(id, privacy: .public)] \(op, privacy: .public) rejected: \(error.description, privacy: .public)")
            return HelperResponse(requestID: request.id, succeeded: false, message: error.description,
                                  bytesReclaimed: nil, durationSeconds: 0)
        } catch {
            logger.error("[\(id, privacy: .public)] \(op, privacy: .public) rejected: \(error.localizedDescription, privacy: .public)")
            return HelperResponse(requestID: request.id, succeeded: false, message: error.localizedDescription,
                                  bytesReclaimed: nil, durationSeconds: 0)
        }

        logger.notice("[\(id, privacy: .public)] \(op, privacy: .public) started")
        let plan = HelperCommandPlan.plan(for: request)
        let start = ContinuousClock.now
        let meter = ReclaimMeter(for: request.operation)
        let outcome = CommandExecutor.run(plan)
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let reclaimed = outcome.succeeded ? meter.bytesReclaimed() : nil

        logger.notice("[\(id, privacy: .public)] \(op, privacy: .public) \(outcome.succeeded ? "succeeded" : "failed", privacy: .public) in \(seconds, format: .fixed(precision: 2), privacy: .public)s: \(outcome.message, privacy: .public)")
        return HelperResponse(requestID: request.id, succeeded: outcome.succeeded, message: outcome.message,
                              bytesReclaimed: reclaimed, durationSeconds: seconds)
    }
}

/// Samples free space (or the target's size) before an operation so the
/// response can report how much it reclaimed.
struct ReclaimMeter {
    private enum Mode {
        case none
        case volumeDelta(before: Int64)
        case directorySize(before: Int64)
    }

    private let mode: Mode

    init(for operation: HelperOperation) {
        switch operation {
        case .freePurgeableSpace, .thinLocalSnapshots:
            mode = .volumeDelta(before: Self.availableCapacity())
        case .removeSystemCache(let path):
            mode = .directorySize(before: Self.allocatedSize(atPath: path))
        default:
            mode = .none
        }
    }

    func bytesReclaimed() -> Int64? {
        switch mode {
        case .none:
            return nil
        case .volumeDelta(let before):
            return max(0, Self.availableCapacity() - before)
        case .directorySize(let before):
            return before
        }
    }

    private static func availableCapacity() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Allocated size of a file or directory tree. Symbolic links are not followed.
    private static func allocatedSize(atPath path: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let url = URL(fileURLWithPath: path)
        func size(of item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return size(of: url) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let item = enumerator?.nextObject() as? URL {
            total += size(of: item)
        }
        return total
    }
}
