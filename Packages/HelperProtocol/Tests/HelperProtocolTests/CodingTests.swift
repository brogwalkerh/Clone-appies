import Foundation
import Testing
@testable import HelperProtocol

@Suite("JSON round trips")
struct CodingTests {
    @Test func requestRoundTripsForEveryOperation() throws {
        for operation in HelperOperation.allSamples {
            let original = HelperRequest(operation: operation, callerHome: validHome)
            let data = try HelperJSON.encode(original)
            let decoded = try HelperJSON.decode(HelperRequest.self, from: data)
            #expect(decoded == original)
            #expect(decoded.id == original.id)
        }
    }

    @Test func requestEncodingIsDeterministic() throws {
        let id = UUID()
        let a = HelperRequest(id: id, operation: .removeSystemCache(path: "/Library/Caches/x"), callerHome: validHome)
        let b = HelperRequest(id: id, operation: .removeSystemCache(path: "/Library/Caches/x"), callerHome: validHome)
        #expect(try HelperJSON.encode(a) == HelperJSON.encode(b))
    }

    @Test func responseRoundTrips() throws {
        let id = UUID()
        let withBytes = HelperResponse(requestID: id, succeeded: true, message: "ok", bytesReclaimed: 42, durationSeconds: 1.5)
        let withoutBytes = HelperResponse(requestID: id, succeeded: false, message: "exit 1: nope", bytesReclaimed: nil, durationSeconds: 0)
        for response in [withBytes, withoutBytes] {
            let decoded = try HelperJSON.decode(HelperResponse.self, from: HelperJSON.encode(response))
            #expect(decoded == response)
        }
    }

    @Test func unparseableRequestIDIsAllZeros() {
        #expect(HelperResponse.unparseableRequestID.uuidString == "00000000-0000-0000-0000-000000000000")
    }

    @Test func commandStepAndPlanRoundTrip() throws {
        let plan = HelperCommandPlan.plan(for: .speedUpMail, callerHome: validHome)
        let decoded = try HelperJSON.decode(HelperCommandPlan.self, from: HelperJSON.encode(plan))
        #expect(decoded == plan)
        #expect(decoded.steps.first?.skipIfMissing != nil)
    }

    @Test func unknownOperationFailsToDecode() {
        let json = Data(#"{"callerHome":"/Users/alice","id":"6E0B8C3C-6B4A-4F1E-9C8B-1D2E3F4A5B6C","operation":{"runShell":{"_0":"rm -rf /"}}}"#.utf8)
        #expect(throws: (any Error).self) {
            try HelperJSON.decode(HelperRequest.self, from: json)
        }
    }

    @Test func garbageFailsToDecode() {
        #expect(throws: (any Error).self) {
            try HelperJSON.decode(HelperRequest.self, from: Data("not json".utf8))
        }
    }
}

@Suite("HelperConstants")
struct ConstantsTests {
    @Test func requirementsNameTheRightIdentifiers() {
        #expect(HelperConstants.clientRequirement.contains("identifier \"com.example.maccleaner\""))
        #expect(HelperConstants.helperRequirement.contains("identifier \"com.example.maccleaner.helper\""))
        #expect(HelperConstants.clientRequirement.hasPrefix("anchor apple generic"))
        #expect(HelperConstants.helperRequirement.hasPrefix("anchor apple generic"))
        #expect(HelperConstants.clientRequirement.contains("certificate leaf[subject.OU] = \"TEAMID_PLACEHOLDER\""))
        #expect(HelperConstants.helperRequirement.contains("certificate leaf[subject.OU] = \"TEAMID_PLACEHOLDER\""))
    }

    @Test func machServiceMatchesLaunchdPlistLabel() {
        #expect(HelperConstants.machServiceName == "com.example.maccleaner.helper")
        #expect(!HelperConstants.version.isEmpty)
    }
}
