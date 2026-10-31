//
//  AccessibilityTreeWalk.swift
//  LocalBrainKit
//
//  The pure halves of two bounded Accessibility walks. The app supplies the
//  attribute reads as closures (so these stay free of the AX API and testable);
//  this file decides what to visit, what to keep and when to stop.
//
//    AccessibilityTreeWalk: the fallback when the point probes found too little.
//      Walks AXChildren breadth first from a window, keeps only elements whose
//      frame overlaps the ink rectangle, and stops at a node budget.
//    AccessibilityLinkResolver: a link with no URL of its own looks a few levels
//      up AXParent for one, and otherwise names what it sits inside.
//
//  Frames are screen frames with a top-left origin, as AX reports them, and the
//  ink rectangle is in the same space.
//

import CoreGraphics
import Foundation

public enum AccessibilityTreeWalk {
    /// Nodes examined at most, across the whole walk.
    public static let maxNodes = 200
    /// Depth below the starting nodes (which are depth 0) that is still visited.
    public static let maxDepth = 6
    /// Fewer usable point-probe elements than this triggers the walk.
    public static let minimumProbeElements = 2

    public struct Result<Node> {
        /// Nodes whose frame overlaps the ink rectangle, nearest the root first.
        public let nodes: [Node]
        /// Nodes examined, counting those that did not overlap.
        public let visited: Int
        /// True when the walk stopped on the node budget or `shouldStop`
        /// before the tree ran out.
        public let stoppedEarly: Bool
    }

    /// True when `frame` overlaps `inkRect`. An empty frame never overlaps
    /// (nothing visible there); the ink rectangle may be thin or flat (a
    /// horizontal line has no height), so edges that touch count.
    public static func frameOverlaps(_ frame: CGRect, inkRect: CGRect) -> Bool {
        guard !frame.isNull, !inkRect.isNull, frame.width > 0, frame.height > 0 else { return false }
        return frame.maxX >= inkRect.minX && frame.minX <= inkRect.maxX
            && frame.maxY >= inkRect.minY && frame.minY <= inkRect.maxY
    }

    /// Breadth-first walk from `roots`.
    ///  - A node is kept when its frame is known and overlaps `inkRect`.
    ///  - A node with a known frame that does not overlap is not descended
    ///    into: its children sit inside it. A node with no frame is still
    ///    descended into (a container may not report one).
    ///  - At most `maxNodes` nodes are examined, and children are only asked
    ///    for while the budget could still use them, so a table with thousands
    ///    of rows is never fully listed.
    ///  - `shouldStop` is checked before each node (the caller's time budget).
    public static func collect<Node>(roots: [Node],
                                     inkRect: CGRect,
                                     maxNodes: Int = AccessibilityTreeWalk.maxNodes,
                                     maxDepth: Int = AccessibilityTreeWalk.maxDepth,
                                     frame: (Node) -> CGRect?,
                                     children: (Node) -> [Node],
                                     shouldStop: () -> Bool = { false }) -> Result<Node> {
        var queue: [(node: Node, depth: Int)] = Array(roots.prefix(max(0, maxNodes))).map { ($0, 0) }
        var head = 0
        var kept: [Node] = []
        var visited = 0
        var stoppedEarly = roots.count > max(0, maxNodes)

        while head < queue.count {
            if visited >= maxNodes || shouldStop() { stoppedEarly = true; break }
            let (node, depth) = queue[head]
            head += 1
            visited += 1

            let known = frame(node)
            if let known, frameOverlaps(known, inkRect: inkRect) { kept.append(node) }
            if let known, !frameOverlaps(known, inkRect: inkRect) { continue }
            guard depth < maxDepth else { continue }

            let room = maxNodes - visited - (queue.count - head)
            guard room > 0 else { continue }
            let below = children(node)
            if below.count > room { stoppedEarly = true }
            queue.append(contentsOf: below.prefix(room).map { ($0, depth + 1) })
        }
        return Result(nodes: kept, visited: visited, stoppedEarly: stoppedEarly)
    }
}

public enum AccessibilityLinkResolver {
    /// AXParent hops tried for an address.
    public static let maxLevels = 3

    public struct Resolution: Equatable, Sendable {
        public let url: String?
        /// Only set when no address was found: the nearest ancestor within
        /// `maxLevels` that has a label, as a short phrase.
        public let linkedFrom: String?
    }

    /// `url` reads an address off one node (nil or blank when it has none);
    /// `label` words one node, for example `group "Navigation"` (nil when it
    /// has nothing worth naming). Never makes more than `maxLevels` calls to
    /// `parent`.
    public static func resolve<Node>(from node: Node,
                                     parent: (Node) -> Node?,
                                     url: (Node) -> String?,
                                     label: (Node) -> String?) -> Resolution {
        if let own = nonBlank(url(node)) { return Resolution(url: own, linkedFrom: nil) }
        var current = node
        var nearestLabel: String?
        for _ in 0..<maxLevels {
            guard let next = parent(current) else { break }
            if let found = nonBlank(url(next)) { return Resolution(url: found, linkedFrom: nil) }
            if nearestLabel == nil { nearestLabel = nonBlank(label(next)) }
            current = next
        }
        return Resolution(url: nil, linkedFrom: nearestLabel)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
