import Foundation
import HelperProtocol
import PerformanceModule

/// Lets the Foundation-only `MaintenanceRunner` reach the privileged helper
/// through the app's XPC client. `HelperClient` is main-actor bound; the
/// adapter hops there for each call, so it is safely `Sendable` itself.
struct HelperPerformerAdapter: HelperPerformer {
    init() {}

    func perform(_ operation: HelperOperation) async throws -> HelperResponse {
        try await HelperClient.shared.perform(operation)
    }
}
