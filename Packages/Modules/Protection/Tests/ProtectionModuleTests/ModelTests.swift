import Foundation
import Testing
import CleanerCore
@testable import ProtectionModule

@Suite("Protection models")
struct ModelTests {
    @Test func threatToFinding() throws {
        let threat = Threat(path: URL(fileURLWithPath: "/Users/test/Downloads/eicar.com"), name: "Eicar-Test-Signature",
                            kind: .signature, severity: .critical, detail: "Matches hash", sizeBytes: 68)
        let finding = threat.finding
        #expect(finding.id == threat.id)
        #expect(finding.path == threat.path)
        #expect(finding.category == FindingCategory(id: "protection.malware", displayName: "Malware", module: .protection))
        #expect(finding.scannerID == "protection.malware")
        #expect(finding.risk == .safe)
        #expect(finding.detail == "Eicar-Test-Signature: Matches hash")
        #expect(finding.sizeBytes == 68)
        #expect(!finding.isDirectory)
        let decoded = try JSONDecoder().decode(Threat.self, from: try JSONEncoder().encode(threat))
        #expect(decoded == threat)
    }

    @Test func severityOrdering() {
        #expect(ThreatSeverity.low < .medium && ThreatSeverity.medium < .high && ThreatSeverity.high < .critical)
        #expect(ThreatSeverity.allCases.max() == .critical)
        #expect(ScanScope.deep.includes(.quick) && ScanScope.normal.includes(.normal) && !ScanScope.quick.includes(.normal))
    }
}

@Suite("Permissions model")
struct PermissionsTests {
    @Test(arguments: [
        ("kTCCServiceCamera", PrivacyService.camera),
        ("kTCCServiceMicrophone", .microphone),
        ("kTCCServiceSystemPolicyAllFiles", .fullDiskAccess),
        ("kTCCServiceAccessibility", .accessibility),
        ("kTCCServiceScreenCapture", .screenRecording),
        ("kTCCServiceLocation", .location),
        ("kTCCServiceAddressBook", .contacts),
        ("kTCCServiceCalendar", .calendars),
        ("kTCCServicePhotos", .photos),
        ("kTCCServiceListenEvent", .inputMonitoring),
        ("kTCCServiceAppleEvents", .automation),
        ("Camera", .camera),
        ("ktccservicescreencapture", .screenRecording),
        ("  kTCCServiceMicrophone\n", .microphone),
    ])
    func mapsTCCServices(raw: String, expected: PrivacyService) {
        #expect(PrivacyService.mapTCCService(raw) == expected)
    }

    @Test(arguments: ["kTCCServiceSystemPolicyDesktopFolder", "kTCCServiceBluetoothAlways", "", "Reminders"])
    func unknownServicesMapToNil(raw: String) {
        #expect(PrivacyService.mapTCCService(raw) == nil)
    }

    @Test func grantIdentityAndCoding() throws {
        let grant = PermissionGrant(service: .camera, clientID: "com.example.app", clientName: "Example",
                                    granted: true, lastModified: testNow)
        #expect(grant.id == "camera:com.example.app")
        let decoded = try JSONDecoder().decode(PermissionGrant.self, from: try JSONEncoder().encode(grant))
        #expect(decoded == grant)
        #expect(PrivacyService.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
