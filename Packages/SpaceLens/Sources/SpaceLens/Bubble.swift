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
}
