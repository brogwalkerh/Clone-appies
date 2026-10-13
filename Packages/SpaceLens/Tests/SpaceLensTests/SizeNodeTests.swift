import Foundation
import Testing
import SpaceLens

@Suite("SizeNode")
struct SizeNodeTests {
    private let root = URL(fileURLWithPath: "/r")

    private func tree() -> SizeNode {
        let d = root.appendingPathComponent("d")
        return SizeNode(id: root, name: "r", sizeBytes: 60, isDirectory: true, children: [
            SizeNode(id: root.appendingPathComponent("a"), name: "a", sizeBytes: 10, isDirectory: false),
            SizeNode(id: d, name: "d", sizeBytes: 30, isDirectory: true, children: [
                SizeNode(id: d.appendingPathComponent("x"), name: "x", sizeBytes: 5, isDirectory: false),
                SizeNode(id: d.appendingPathComponent("y"), name: "y", sizeBytes: 25, isDirectory: false),
            ]),
            SizeNode(id: root.appendingPathComponent("b"), name: "b", sizeBytes: 20, isDirectory: false),
        ])
    }

    @Test func sortedOrdersRecursively() {
        let s = tree().sorted()
        #expect(s.children.map(\.name) == ["d", "b", "a"])
        #expect(s.children[0].children.map(\.name) == ["y", "x"])
        #expect(s.sizeBytes == 60)
    }

    @Test func sortedBreaksTiesByName() {
        let n = SizeNode(id: root, name: "r", sizeBytes: 3, isDirectory: true, children: [
            SizeNode(id: root.appendingPathComponent("c"), name: "c", sizeBytes: 1, isDirectory: false),
            SizeNode(id: root.appendingPathComponent("a"), name: "a", sizeBytes: 1, isDirectory: false),
            SizeNode(id: root.appendingPathComponent("b"), name: "b", sizeBytes: 1, isDirectory: false),
        ])
        #expect(n.sorted().children.map(\.name) == ["a", "b", "c"])
    }

    @Test func findLocatesNestedNodes() {
        let t = tree()
        #expect(t.find(id: root)?.name == "r")
        #expect(t.find(id: root.appendingPathComponent("d").appendingPathComponent("y"))?.sizeBytes == 25)
        #expect(t.find(id: root.appendingPathComponent("nope")) == nil)
    }
}
