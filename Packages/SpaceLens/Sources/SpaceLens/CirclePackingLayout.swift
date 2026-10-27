import Foundation

/// Front-chain circle packing (Wang, Wang, Dai & Wang 2006, as implemented by
/// d3-hierarchy's `pack`) for the Space Lens bubble map.
///
/// Semantics:
/// - `node.children` are laid out inside the circle of `radius` at `center`,
///   sorted by size descending (ties: name, then path).
/// - Each child's radius is proportional to `sqrt(sizeBytes)`. The proportionality
///   constant is found by packing once with unit scale, computing the minimum
///   enclosing circle of the packed siblings, and scaling so that circle (plus
///   padding) exactly fits the parent.
/// - `padding` is the approximate gap, in output units, between adjacent circles
///   and between a circle and the parent boundary.
/// - Directories are laid out recursively, each child's bubble becoming the new
///   parent, down to `maxDepth`. Direct children have `depth == 1`.
/// - Children whose final radius would be below `minRadius` are collapsed into a
///   single synthetic "N more items" bubble. Its `node` is a synthetic `SizeNode`
///   with `id == parent.id.appendingPathComponent("…")`, `name == "N more items"`,
///   `sizeBytes` equal to the sum of the collapsed children, `isDirectory == false`
///   (so the layout never recurses into it) and `children` holding the collapsed
///   nodes so a UI can still drill into them. The synthetic bubble is itself
///   omitted when even it would be below `minRadius` (i.e. the parent is tiny).
/// - Output is deterministic for identical input: no randomness is used anywhere.
public struct CirclePackingLayout: Sendable {
    public let padding: Double
    public let minRadius: Double

    public init(padding: Double = 2, minRadius: Double = 3) {
        self.padding = max(0, padding)
        self.minRadius = max(0, minRadius)
    }

    /// Lays out `node.children` inside a circle of `radius` centered at `center`.
    ///
    /// Returned bubbles are in pre-order: each child (largest first) followed by
    /// its own descendants. An empty `node.children` yields `[]`.
    public func layout(_ node: SizeNode, in radius: Double, center: CGPoint, maxDepth: Int = 2) -> [Bubble] {
        var out: [Bubble] = []
        layout(node, radius: radius, center: center, depth: 1, maxDepth: maxDepth, into: &out)
        return out
    }

    // MARK: - Recursive driver

    private func layout(_ node: SizeNode, radius: Double, center: CGPoint, depth: Int, maxDepth: Int,
                        into out: inout [Bubble]) {
        guard depth <= maxDepth, radius.isFinite, radius > padding, !node.children.isEmpty else { return }

        let children = node.children.sorted(by: SizeNode.sizeDescending)
        let placed = packLevel(children, parentID: node.id, radius: radius)

        for item in placed {
            let bubble = Bubble(
                id: item.node.id,
                center: CGPoint(x: Double(center.x) + item.x, y: Double(center.y) + item.y),
                radius: item.r,
                depth: depth,
                node: item.node
            )
            out.append(bubble)
            if item.node.isDirectory, !item.node.children.isEmpty {
                layout(item.node, radius: item.r, center: bubble.center, depth: depth + 1, maxDepth: maxDepth, into: &out)
            }
        }
    }

    // MARK: - One level

    private struct Placed {
        var node: SizeNode
        var x: Double
        var y: Double
        var r: Double
    }

    /// Packs one sibling set into a circle of `radius` centered at the origin,
    /// collapsing sub-`minRadius` children into the synthetic overflow bubble.
    private func packLevel(_ sortedChildren: [SizeNode], parentID: URL, radius: Double) -> [Placed] {
        var visible = sortedChildren
        var collapsed: [SizeNode] = []
        let overflowID = parentID.appendingPathComponent("…")

        // Iterate until no visible (non-synthetic) child falls below minRadius.
        // Each iteration strictly shrinks `visible`, so this terminates.
        for _ in 0...sortedChildren.count {
            let nodes = visible + (collapsed.isEmpty ? [] : [overflowNode(id: overflowID, members: collapsed)])
            guard !nodes.isEmpty else { return [] }
            let result = pack(nodes, radius: radius)

            var tiny: [SizeNode] = []
            var kept: [SizeNode] = []
            for (node, circle) in zip(nodes, result) where node.id != overflowID {
                if circle.r < minRadius { tiny.append(node) } else { kept.append(node) }
            }
            if tiny.isEmpty {
                var placed = zip(nodes, result).map { Placed(node: $0, x: $1.x, y: $1.y, r: $1.r) }
                // Drop the overflow bubble if even it is too small to show.
                placed.removeAll { $0.node.id == overflowID && $0.r < minRadius }
                return placed
            }
            visible = kept
            collapsed.append(contentsOf: tiny)
        }
        return []
    }

    private func overflowNode(id: URL, members: [SizeNode]) -> SizeNode {
        let total = members.reduce(Int64(0)) { $0 &+ max(0, $1.sizeBytes) }
        let name = members.count == 1 ? "1 more item" : "\(members.count) more items"
        return SizeNode(id: id, name: name, sizeBytes: total, isDirectory: false,
                        children: members.sorted(by: SizeNode.sizeDescending))
    }

    /// Packs `nodes` (already in display order) so they fit a parent circle of
    /// `radius` centered at the origin, honoring `padding`.
    private func pack(_ nodes: [SizeNode], radius: Double) -> [Circle] {
        // Unit radii: sqrt(size), normalized so the largest is 1 (keeps float
        // error uniform regardless of absolute byte counts). All-zero sizes get
        // equal radii so they are still drawn.
        var unit = nodes.map { Double(max(0, $0.sizeBytes)).squareRoot() }
        let maxUnit = unit.max() ?? 0
        if maxUnit > 0 {
            unit = unit.map { $0 / maxUnit }
        } else {
            unit = unit.map { _ in 1 }
        }
        // Zero-size children next to non-zero ones: give them a vanishing radius
        // so the packer still has a well-defined geometry.
        unit = unit.map { max($0, 1e-9) }

        // Pass 1: no padding. Gives the scale used to express padding in unit space.
        var circles = unit.map { Circle(x: 0, y: 0, r: $0) }
        let enclosing1 = FrontChainPacker.pack(&circles)
        guard enclosing1 > 0 else { return circles.map { _ in Circle(x: 0, y: 0, r: 0) } }
        let scale1 = radius / enclosing1

        // Pass 2: grow every circle by half the padding (in unit space), pack,
        // then shrink back. Adjacent circles end up ~`padding` apart and the
        // enclosing circle is grown by the same half padding so the gap to the
        // parent boundary matches.
        let halfPad = (padding / 2) / scale1
        if halfPad > 0 {
            circles = unit.map { Circle(x: 0, y: 0, r: $0 + halfPad) }
            let enclosing2 = FrontChainPacker.pack(&circles) + halfPad
            let scale2 = radius / enclosing2
            return circles.map { Circle(x: $0.x * scale2, y: $0.y * scale2, r: ($0.r - halfPad) * scale2) }
        }
        return circles.map { Circle(x: $0.x * scale1, y: $0.y * scale1, r: $0.r * scale1) }
    }
}

// MARK: - Geometry primitives

struct Circle: Sendable, Equatable {
    var x: Double
    var y: Double
    var r: Double
}

/// Deterministic port of d3-hierarchy's `packSiblings` (front-chain packing) and
/// `packEnclose` (Welzl-style minimum enclosing circle, without the random shuffle).
enum FrontChainPacker {
    /// Relative tolerance used when testing whether two circles intersect, so that
    /// circles placed tangent by `place` are not rejected due to rounding.
    private static let epsilon = 1e-9

    /// Packs `circles` around the origin in input order, mutating their centers.
    /// Returns the radius of the minimum enclosing circle (centered at the origin
    /// after translation).
    static func pack(_ circles: inout [Circle]) -> Double {
        let n = circles.count
        guard n > 0 else { return 0 }

        circles[0].x = 0
        circles[0].y = 0
        guard n > 1 else { return circles[0].r }

        circles[0].x = -circles[1].r
        circles[1].x = circles[0].r
        circles[1].y = 0
        guard n > 2 else { return circles[0].r + circles[1].r }

        place(b: circles[1], a: circles[0], c: &circles[2])

        // Front chain as a doubly linked list over indices.
        var next = [Int](repeating: -1, count: n)
        var prev = [Int](repeating: -1, count: n)
        var a = 0, b = 1, c = 2
        next[a] = b; prev[b] = a
        next[b] = c; prev[c] = b
        next[c] = a; prev[a] = c

        var i = 3
        pack: while i < n {
            c = i
            place(b: circles[a], a: circles[b], c: &circles[c])

            // Find the closest intersecting circle on the front chain, if any.
            // Closeness is linear distance along the chain, ahead (j) or behind (k).
            var j = next[b], k = prev[a]
            var sj = circles[b].r, sk = circles[a].r
            repeat {
                if sj <= sk {
                    if intersects(circles[j], circles[c]) {
                        b = j; next[a] = b; prev[b] = a
                        continue pack
                    }
                    sj += circles[j].r; j = next[j]
                } else {
                    if intersects(circles[k], circles[c]) {
                        a = k; next[a] = b; prev[b] = a
                        continue pack
                    }
                    sk += circles[k].r; k = prev[k]
                }
            } while j != next[k]

            // Success: insert c between a and b.
            prev[c] = a; next[c] = b
            next[a] = c; prev[b] = c
            b = c

            // New closest pair to the centroid becomes the insertion point.
            var aa = score(a, next[a], circles)
            var cursor = next[c]
            while cursor != b {
                let ca = score(cursor, next[cursor], circles)
                if ca < aa { a = cursor; aa = ca }
                cursor = next[cursor]
            }
            b = next[a]
            i += 1
        }

        // Minimum enclosing circle of the front chain, then recenter on it.
        var chain: [Circle] = [circles[b]]
        var cursor = next[b]
        while cursor != b {
            chain.append(circles[cursor])
            cursor = next[cursor]
        }
        let e = enclose(chain)
        for idx in 0..<n {
            circles[idx].x -= e.x
            circles[idx].y -= e.y
        }
        return e.r
    }

    /// Places `c` tangent to both `a` and `b`, on the side given by the chain orientation.
    private static func place(b: Circle, a: Circle, c: inout Circle) {
        let dx = b.x - a.x, dy = b.y - a.y
        let d2 = dx * dx + dy * dy
        if d2 > 0 {
            var a2 = a.r + c.r; a2 *= a2
            var b2 = b.r + c.r; b2 *= b2
            if a2 > b2 {
                let x = (d2 + b2 - a2) / (2 * d2)
                let y = max(0, b2 / d2 - x * x).squareRoot()
                c.x = b.x - x * dx - y * dy
                c.y = b.y - x * dy + y * dx
            } else {
                let x = (d2 + a2 - b2) / (2 * d2)
                let y = max(0, a2 / d2 - x * x).squareRoot()
                c.x = a.x + x * dx - y * dy
                c.y = a.y + x * dy + y * dx
            }
        } else {
            c.x = a.x + c.r
            c.y = a.y
        }
    }

    private static func intersects(_ a: Circle, _ b: Circle) -> Bool {
        let sum = a.r + b.r
        let dr = sum - epsilon * sum
        let dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    /// Squared distance from the origin of the weighted midpoint of two adjacent chain circles.
    private static func score(_ i: Int, _ j: Int, _ circles: [Circle]) -> Double {
        let a = circles[i], b = circles[j]
        let ab = a.r + b.r
        let dx = (a.x * b.r + b.x * a.r) / ab
        let dy = (a.y * b.r + b.y * a.r) / ab
        return dx * dx + dy * dy
    }

    // MARK: Minimum enclosing circle (Welzl, move-to-front, deterministic)

    static func enclose(_ circles: [Circle]) -> Circle {
        guard !circles.isEmpty else { return Circle(x: 0, y: 0, r: 0) }
        var basis: [Circle] = []
        var e: Circle? = nil
        var i = 0
        let n = circles.count
        var steps = 0
        let stepLimit = n * n * 4 + 64
        while i < n {
            steps += 1
            if steps > stepLimit { return conservativeEnclose(circles) }
            let p = circles[i]
            if let current = e, enclosesWeak(current, p) {
                i += 1
            } else {
                guard let extended = extendBasis(basis, p) else { return conservativeEnclose(circles) }
                basis = extended
                e = encloseBasis(basis)
                i = 0
            }
        }
        return e ?? conservativeEnclose(circles)
    }

    /// Fallback if the basis search degenerates numerically: a circle around the
    /// centroid that certainly contains every input circle.
    private static func conservativeEnclose(_ circles: [Circle]) -> Circle {
        let cx = circles.reduce(0.0) { $0 + $1.x } / Double(circles.count)
        let cy = circles.reduce(0.0) { $0 + $1.y } / Double(circles.count)
        let r = circles.reduce(0.0) { acc, c in
            max(acc, ((c.x - cx) * (c.x - cx) + (c.y - cy) * (c.y - cy)).squareRoot() + c.r)
        }
        return Circle(x: cx, y: cy, r: r)
    }

    private static func extendBasis(_ B: [Circle], _ p: Circle) -> [Circle]? {
        if enclosesWeakAll(p, B) { return [p] }
        for i in 0..<B.count {
            if enclosesNot(p, B[i]), enclosesWeakAll(encloseBasis2(B[i], p), B) {
                return [B[i], p]
            }
        }
        if B.count >= 2 {
            for i in 0..<(B.count - 1) {
                for j in (i + 1)..<B.count {
                    if enclosesNot(encloseBasis2(B[i], B[j]), p),
                       enclosesNot(encloseBasis2(B[i], p), B[j]),
                       enclosesNot(encloseBasis2(B[j], p), B[i]),
                       enclosesWeakAll(encloseBasis3(B[i], B[j], p), B) {
                        return [B[i], B[j], p]
                    }
                }
            }
        }
        return nil
    }

    private static func enclosesNot(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r, dx = b.x - a.x, dy = b.y - a.y
        return dr < 0 || dr * dr < dx * dx + dy * dy
    }

    private static func enclosesWeak(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r + max(a.r, b.r, 1) * 1e-9
        let dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    private static func enclosesWeakAll(_ a: Circle, _ B: [Circle]) -> Bool {
        B.allSatisfy { enclosesWeak(a, $0) }
    }

    private static func encloseBasis(_ B: [Circle]) -> Circle {
        switch B.count {
        case 1: return B[0]
        case 2: return encloseBasis2(B[0], B[1])
        default: return encloseBasis3(B[0], B[1], B[2])
        }
    }

    private static func encloseBasis2(_ a: Circle, _ b: Circle) -> Circle {
        let x21 = b.x - a.x, y21 = b.y - a.y, r21 = b.r - a.r
        let l = (x21 * x21 + y21 * y21).squareRoot()
        guard l > 0 else { return a.r >= b.r ? a : b }
        return Circle(
            x: (a.x + b.x + x21 / l * r21) / 2,
            y: (a.y + b.y + y21 / l * r21) / 2,
            r: (l + a.r + b.r) / 2
        )
    }

    private static func encloseBasis3(_ a: Circle, _ b: Circle, _ c: Circle) -> Circle {
        let x1 = a.x, y1 = a.y, r1 = a.r
        let x2 = b.x, y2 = b.y, r2 = b.r
        let x3 = c.x, y3 = c.y, r3 = c.r
        let a2 = x1 - x2, a3 = x1 - x3
        let b2 = y1 - y2, b3 = y1 - y3
        let c2 = r2 - r1, c3 = r3 - r1
        let d1 = x1 * x1 + y1 * y1 - r1 * r1
        let d2 = d1 - x2 * x2 - y2 * y2 + r2 * r2
        let d3 = d1 - x3 * x3 - y3 * y3 + r3 * r3
        let ab = a3 * b2 - a2 * b3
        guard ab != 0 else { return conservativeEnclose([a, b, c]) }
        let xa = (b2 * d3 - b3 * d2) / (ab * 2) - x1
        let xb = (b3 * c2 - b2 * c3) / ab
        let ya = (a3 * d2 - a2 * d3) / (ab * 2) - y1
        let yb = (a2 * c3 - a3 * c2) / ab
        let A = xb * xb + yb * yb - 1
        let B = 2 * (r1 + xa * xb + ya * yb)
        let C = xa * xa + ya * ya - r1 * r1
        let r: Double
        if abs(A) > 1e-6 {
            r = -((B + max(0, B * B - 4 * A * C).squareRoot()) / (2 * A))
        } else if B != 0 {
            r = -(C / B)
        } else {
            return conservativeEnclose([a, b, c])
        }
        guard r.isFinite, r >= 0 else { return conservativeEnclose([a, b, c]) }
        return Circle(x: x1 + xa + xb * r, y: y1 + ya + yb * r, r: r)
    }
}
