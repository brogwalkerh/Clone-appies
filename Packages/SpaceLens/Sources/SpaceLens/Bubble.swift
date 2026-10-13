import Foundation

/// A positioned circle produced by `CirclePackingLayout`.
///
/// `depth` is 1 for direct children of the node that was laid out, 2 for their
/// children, and so on. `node` is the `SizeNode` the bubble represents; for the
/// synthetic overflow bubble (see `CirclePackingLayout`) it is a synthetic node
/// whose `id` is `parent.id.appendingPathComponent("…")`.
public struct Bubble: Sendable, Hashable, Identifiable {
    public let id: URL
    public let center: CGPoint
    public let radius: Double
    public let depth: Int
    public let node: SizeNode

    public init(id: URL, center: CGPoint, radius: Double, depth: Int, node: SizeNode) {
        self.id = id
        self.center = center
        self.radius = radius
        self.depth = depth
        self.node = node
    }

    // `CGPoint` is Hashable in swift-corelibs-foundation (Linux) but only
    // Equatable in CoreGraphics (Darwin), so conformance is spelled out here
    // to keep the type identical on both platforms.
    public static func == (lhs: Bubble, rhs: Bubble) -> Bool {
        lhs.id == rhs.id
            && lhs.center.x == rhs.center.x
            && lhs.center.y == rhs.center.y
            && lhs.radius == rhs.radius
            && lhs.depth == rhs.depth
            && lhs.node == rhs.node
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(center.x)
        hasher.combine(center.y)
        hasher.combine(radius)
        hasher.combine(depth)
        hasher.combine(node)
    }
}
