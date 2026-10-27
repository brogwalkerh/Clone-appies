import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("InfoPlist")
struct InfoPlistTests {
    @Test func parsesXMLPlistFromMockFileSystem() throws {
        let fs: MockFileSystem = [
            "/Applications/Fancy.app/Contents/Info.plist": infoPlist(
                name: "Fancy", displayName: "Fancy Pro", executable: "Fancy", id: "com.vendor.fancy",
                version: "2.1.0", build: "2100", feed: "https://example.com/appcast.xml",
                extra: "    <key>LSUIElement</key>\n    <true/>\n"),
        ]
        let data = try fs.contents(of: URL(fileURLWithPath: "/Applications/Fancy.app/Contents/Info.plist"))
        let plist = try InfoPlist(data: data)
        #expect(plist.bundleName == "Fancy")
        #expect(plist.displayName == "Fancy Pro")
        #expect(plist.executable == "Fancy")
        #expect(plist.bundleIdentifier == "com.vendor.fancy")
        #expect(plist.shortVersion == "2.1.0")
        #expect(plist.bundleVersion == "2100")
        #expect(plist.sparkleFeedURL == "https://example.com/appcast.xml")
        #expect(plist.isUIElement)
        #expect(plist.preferredName == "Fancy")
    }

    @Test func nameFallbackOrder() throws {
        #expect(try InfoPlist(data: infoPlistData(displayName: "Display", executable: "Exec")).preferredName == "Display")
        #expect(try InfoPlist(data: infoPlistData(executable: "Exec")).preferredName == "Exec")
        #expect(try InfoPlist(data: infoPlistData(id: "com.x.y")).preferredName == nil)
        #expect(try InfoPlist(data: infoPlistData(name: "  ", executable: "Exec")).preferredName == "Exec")
    }

    @Test func toleratesNumericAndStringVariants() throws {
        let extra = """
            <key>CFBundleVersion</key>
            <integer>42</integer>
            <key>LSUIElement</key>
            <string>1</string>
        """
        let plist = try InfoPlist(data: infoPlistData(name: "A", id: "com.a.b", extra: extra))
        #expect(plist.bundleVersion == "42")
        #expect(plist.isUIElement)
        let off = try InfoPlist(data: infoPlistData(name: "A", extra: "<key>LSUIElement</key><string>0</string>"))
        #expect(!off.isUIElement)
        let missing = try InfoPlist(data: infoPlistData(name: "A"))
        #expect(!missing.isUIElement)
        #expect(missing.bundleIdentifier == nil)
        #expect(missing.sparkleFeedURL == nil)
    }

    @Test func parsesBinaryPlist() throws {
        let dict: [String: Any] = [
            "CFBundleName": "Bin", "CFBundleIdentifier": "com.vendor.bin",
            "CFBundleShortVersionString": "3.0", "CFBundleVersion": "300", "LSUIElement": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let plist = try InfoPlist(data: data)
        #expect(plist.bundleName == "Bin")
        #expect(plist.bundleIdentifier == "com.vendor.bin")
        #expect(plist.shortVersion == "3.0")
        #expect(plist.bundleVersion == "300")
        #expect(plist.isUIElement)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try InfoPlist(data: Data("not a plist".utf8)) }
    }
}
