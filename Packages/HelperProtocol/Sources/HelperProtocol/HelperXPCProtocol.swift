#if canImport(ObjectiveC)
import Foundation

/// XPC wire protocol. Payloads are JSON (`HelperJSON`) so the ObjC surface
/// carries only `Data`/`String`; the typed contract lives in `HelperRequest`.
@objc public protocol HelperXPCProtocol {
    /// JSON `HelperRequest` in, JSON `HelperResponse` out.
    func perform(_ requestData: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Returns `HelperConstants.version` of the running helper.
    func version(reply: @escaping @Sendable (String) -> Void)
}
#endif
