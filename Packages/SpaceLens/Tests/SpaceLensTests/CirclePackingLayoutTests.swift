import Foundation
import Testing
@testable import SpaceLens

// MARK: - Fixtures

private let rootURL = URL(fileURLWithPath: "/fixture")

private func leaf(_ name: String, _ size: Int64, under parent: URL = rootURL) -> SizeNode {
    SizeNode(id: parent.appendingPathComponent(name), name: name, sizeBytes: size, isDirectory: false)
}

private func dir(_ name: String, under parent: URL = rootURL, _ children: [SizeNode]) -> SizeNode {
    let id = parent.appendingPathComponent(name)
    let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
    return SizeNode(id: id, name: name, sizeBytes: total, isDirectory: true, children: children)
}

private func node(sizes: [Int64]) -> SizeNode {
    let children = sizes.enumerated().map { leaf("f\($0.offset)", $0.element) }
    return SizeNode(id: rootURL, name: "fixture", sizeBytes: sizes.reduce(0, +), isDirectory: true, children: children)
}

/// A "typical" nested tree: mixed sizes, a few directories, some tiny files.
private func sampleTree() -> SizeNode {
    let apps = rootURL.appendingPathComponent("Applications")
    let lib = rootURL.appendingPathComponent("Library")
    let caches = lib.appendingPathComponent("Caches")
    return dir("fixture", under: URL(fileURLWithPath: "/"), [
        dir("Applications", [
            leaf("Xcode.app", 30_000_000_000, under: apps),
            leaf("Safari.app", 400_000_000, under: apps),
            leaf("Notes.app", 50_000_000, under: apps),
        ]),
        dir("Library", [
            dir("Caches", under: lib, [
                leaf("a", 900_000_000, under: caches),
                leaf("b", 300_000_000, under: caches),
                leaf("c", 10_000, under: caches),
            ]),
            leaf("prefs.plist", 2_000, under: lib),
        ]),
        leaf("movie.mov", 12_000_000_000),
        leaf("photo.jpg", 4_000_000),
        leaf("note.txt", 120),
    ])
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
}

private func siblings(_ bubbles: [Bubble], depth: Int, parent: URL?) -> [Bubble] {
    bubbles.filter { $0.depth == depth && (parent == nil || $0.id.deletingLastPathComponent() == parent) }
}

/// Asserts the structural invariants for every bubble in `bubbles`.
private func assertInvariants(_ bubbles: [Bubble], root: SizeNode, radius: Double, center: CGPoint,
                              padding: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    // Group siblings by their parent bubble (or the root circle for depth 1).
    var parentCircle: [String: (CGPoint, Double)] = [root.id.standardizedFileURL.path: (center, radius)]
    for b in bubbles { parentCircle[b.id.standardizedFileURL.path] = (b.center, b.radius) }

    var groups: [String: [Bubble]] = [:]
    for b in bubbles {
        groups[b.id.deletingLastPathComponent().standardizedFileURL.path, default: []].append(b)
    }

    for (parentID, group) in groups {
        guard let (pc, pr) = parentCircle[parentID] else {
            Issue.record("bubble group has unknown parent \(parentID)", sourceLocation: sourceLocation)
            continue
        }
        for b in group {
            // Within the parent.
            #expect(distance(b.center, pc) + b.radius <= pr + 1e-6,
                    "\(b.node.name) escapes parent \(parentID)", sourceLocation: sourceLocation)
            #expect(b.radius > 0, sourceLocation: sourceLocation)
        }
        // No overlaps between siblings (tolerating padding shrinkage).
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                let a = group[i], b = group[j]
                #expect(distance(a.center, b.center) >= a.radius + b.radius - 1e-6,
                        "\(a.node.name) overlaps \(b.node.name)", sourceLocation: sourceLocation)
            }
        }
        // Sizes monotonic with radius.
        let sorted = group.sorted { $0.node.sizeBytes > $1.node.sizeBytes }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a.radius >= b.radius - 1e-9, "radius not monotonic: \(a.node.name) vs \(b.node.name)",
                    sourceLocation: sourceLocation)
            if a.node.sizeBytes == b.node.sizeBytes {
                #expect(abs(a.radius - b.radius) < 1e-9, sourceLocation: sourceLocation)
            }
        }
    }
    _ = padding
}

// MARK: - Tests

private let invariantCases: [[Int64]] = {
    var cases: [[Int64]] = []
    cases.append((1...12).map { Int64($0) * 1_000 })
    cases.append([1_000_000, 1, 1, 1, 1, 1])
    cases.append([Int64](repeating: 777, count: 40))
    cases.append([0, 0, 0, 10])
    cases.append([0, 0, 0])
    cases.append((0..<300).map { Int64(1 + ($0 * 7919) % 10_007) })
    return cases
}()

@Suite("CirclePackingLayout")
struct CirclePackingLayoutTests {
    let center = CGPoint(x: 400, y: 300)

    @Test("empty node yields no bubbles")
    func emptyNode() {
        let empty = SizeNode(id: rootURL, name: "empty", sizeBytes: 0, isDirectory: true)
        #expect(CirclePackingLayout().layout(empty, in: 200, center: center).isEmpty)
        let file = SizeNode(id: rootURL, name: "file", sizeBytes: 10, isDirectory: false)
        #expect(CirclePackingLayout().layout(file, in: 200, center: center).isEmpty)
        // A degenerate parent radius yields nothing either.
        #expect(CirclePackingLayout().layout(sampleTree(), in: 0, center: center).isEmpty)
    }

    @Test("a single child fills most of the parent")
    func singleChild() {
        let layout = CirclePackingLayout(padding: 2, minRadius: 3)
        let bubbles = layout.layout(node(sizes: [1_000]), in: 100, center: center)
        #expect(bubbles.count == 1)
        let b = bubbles[0]
        // Gap to the parent boundary is ~padding (2): 100 / 1.02 = 98.04.
        #expect(b.radius > 97.5 && b.radius < 98.5, "radius \(b.radius)")
        #expect(distance(b.center, center) < 1e-9)
        #expect(b.depth == 1)
    }

    @Test("children are sorted by size descending")
    func sortedOutput() {
        let bubbles = CirclePackingLayout(minRadius: 0).layout(node(sizes: [5, 500, 50, 5_000]), in: 100, center: center)
        #expect(bubbles.map(\.node.sizeBytes) == [5_000, 500, 50, 5])
    }

    @Test("a sub-minRadius overflow bubble is dropped rather than drawn")
    func tinyOverflowDropped() {
        // The 5-byte child is below minRadius; its overflow bubble would be too, so neither appears.
        let bubbles = CirclePackingLayout(padding: 2, minRadius: 3).layout(node(sizes: [5, 500, 50, 5_000]), in: 100, center: center)
        #expect(bubbles.map(\.node.sizeBytes) == [5_000, 500, 50])
        #expect(bubbles.allSatisfy { $0.radius >= 3 })
    }

    @Test("siblings never overlap, stay inside the parent, radii follow sizes", arguments: invariantCases)
    func invariants(sizes: [Int64]) {
        for padding in [0.0, 2.0, 7.5] {
            let layout = CirclePackingLayout(padding: padding, minRadius: 0)
            let root = node(sizes: sizes)
            let bubbles = layout.layout(root, in: 250, center: center)
            #expect(bubbles.count == sizes.count)
            assertInvariants(bubbles, root: root, radius: 250, center: center, padding: padding)
        }
    }

    @Test("nested directories recurse up to maxDepth and keep invariants")
    func nested() {
        let tree = sampleTree()
        let layout = CirclePackingLayout(padding: 2, minRadius: 0)

        let depth1 = layout.layout(tree, in: 300, center: center, maxDepth: 1)
        #expect(Set(depth1.map(\.depth)) == [1])
        #expect(depth1.count == tree.children.count)

        let depth2 = layout.layout(tree, in: 300, center: center, maxDepth: 2)
        #expect(depth2.contains { $0.depth == 2 })
        #expect(!depth2.contains { $0.depth == 3 })
        assertInvariants(depth2, root: tree, radius: 300, center: center, padding: 2)

        let depth3 = layout.layout(tree, in: 300, center: center, maxDepth: 3)
        #expect(depth3.contains { $0.depth == 3 && $0.node.name == "a" })
        assertInvariants(depth3, root: tree, radius: 300, center: center, padding: 2)

        // Pre-order: a directory's descendants directly follow it.
        let appsIndex = depth2.firstIndex { $0.node.name == "Applications" }!
        #expect(depth2[appsIndex + 1].node.name == "Xcode.app")
        #expect(depth2[appsIndex + 1].depth == 2)
    }

    @Test("padding separates adjacent siblings")
    func paddingApplied() {
        let sizes: [Int64] = [Int64](repeating: 1_000, count: 7)
        let padded = CirclePackingLayout(padding: 6, minRadius: 0).layout(node(sizes: sizes), in: 200, center: center)
        var minGap = Double.infinity
        for i in 0..<padded.count {
            for j in (i + 1)..<padded.count {
                minGap = min(minGap, distance(padded[i].center, padded[j].center) - padded[i].radius - padded[j].radius)
            }
        }
        // Approximate padding: within 10% of the requested value.
        #expect(minGap > 5.0 && minGap < 6.5, "min gap \(minGap)")
    }

    @Test("deterministic output for identical input")
    func determinism() {
        let tree = sampleTree()
        let layout = CirclePackingLayout()
        let a = layout.layout(tree, in: 300, center: center, maxDepth: 3)
        let b = layout.layout(tree, in: 300, center: center, maxDepth: 3)
        #expect(a == b)
        // Input order of children must not matter either.
        var shuffled = tree
        shuffled.children.reverse()
        let c = layout.layout(shuffled, in: 300, center: center, maxDepth: 3)
        #expect(a == c)
    }

    @Test("many tiny children collapse into a synthetic overflow bubble")
    func overflow() {
        var sizes: [Int64] = [10_000_000, 2_000_000]
        sizes += [Int64](repeating: 2_000, count: 500)   // each ~2pt, together ~50pt
        let root = node(sizes: sizes)
        let layout = CirclePackingLayout(padding: 2, minRadius: 3)
        let bubbles = layout.layout(root, in: 200, center: center)

        let overflowID = rootURL.appendingPathComponent("…")
        let overflow = bubbles.first { $0.id == overflowID }
        #expect(overflow != nil)
        #expect(bubbles.count < sizes.count)
        #expect(bubbles.allSatisfy { $0.radius >= 3 - 1e-9 })
        if let overflow {
            #expect(overflow.node.name == "500 more items")
            #expect(overflow.node.sizeBytes == 500 * 2_000)
            #expect(overflow.node.isDirectory == false)
            #expect(overflow.node.children.count == 500)
        }
        // The big ones survive untouched.
        #expect(bubbles.contains { $0.node.sizeBytes == 10_000_000 })
        #expect(bubbles.contains { $0.node.sizeBytes == 2_000_000 })
        #expect(bubbles.count == 3)
        assertInvariants(bubbles, root: root, radius: 200, center: center, padding: 2)
    }

    @Test("overflow bubble is not emitted when nothing is collapsed")
    func noOverflowWhenNotNeeded() {
        let bubbles = CirclePackingLayout(padding: 2, minRadius: 3).layout(node(sizes: [100, 200, 300]), in: 200, center: center)
        #expect(!bubbles.contains { $0.id == rootURL.appendingPathComponent("…") })
        #expect(bubbles.count == 3)
    }

    @Test("performance: 2,000 children lay out quickly (informational)")
    func performance() {
        let sizes = (0..<2_000).map { Int64(1_000 + ($0 * 104_729) % 5_000_000) }
        let root = node(sizes: sizes)
        let layout = CirclePackingLayout(padding: 1, minRadius: 0)
        _ = layout.layout(root, in: 500, center: center) // warm-up
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = layout.layout(root, in: 500, center: center)
        }
        let bubbles = layout.layout(root, in: 500, center: center)
        #expect(bubbles.count == 2_000)
        print("[SpaceLens] 2,000-child layout took \(elapsed) (target < 1s, informational only)")
        if elapsed > .seconds(1) {
            print("[SpaceLens] WARNING: layout slower than the 1s budget on this runner")
        }
    }
}

@Suite("FrontChainPacker")
struct FrontChainPackerTests {
    @Test("enclosing circle contains every packed circle")
    func encloseContainsAll() {
        var circles = (0..<60).map { Circle(x: 0, y: 0, r: Double(1 + $0 % 7)) }
        let r = FrontChainPacker.pack(&circles)
        for c in circles {
            #expect((c.x * c.x + c.y * c.y).squareRoot() + c.r <= r + 1e-6)
        }
    }

    @Test("enclose of a single and of two circles")
    func encloseSmall() {
        let one = FrontChainPacker.enclose([Circle(x: 3, y: 4, r: 2)])
        #expect(one == Circle(x: 3, y: 4, r: 2))
        let two = FrontChainPacker.enclose([Circle(x: -1, y: 0, r: 1), Circle(x: 1, y: 0, r: 1)])
        #expect(abs(two.x) < 1e-9 && abs(two.y) < 1e-9 && abs(two.r - 2) < 1e-9)
    }
}
