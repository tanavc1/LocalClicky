import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class AccessibilityTreeWalkTests: XCTestCase {
    /// A small tree for the closures.
    private final class Node {
        let name: String
        let frame: CGRect?
        var kids: [Node]
        var parent: Node?
        var url: String?
        var label: String?
        var childReads = 0
        init(_ name: String, _ frame: CGRect?, _ kids: [Node] = []) {
            self.name = name
            self.frame = frame
            self.kids = kids
            kids.forEach { $0.parent = self }
        }
    }

    private let ink = CGRect(x: 100, y: 100, width: 50, height: 50)

    private func walk(_ roots: [Node], maxNodes: Int = 200, maxDepth: Int = 6,
                      shouldStop: @escaping () -> Bool = { false }) -> AccessibilityTreeWalk.Result<Node> {
        AccessibilityTreeWalk.collect(roots: roots, inkRect: ink, maxNodes: maxNodes, maxDepth: maxDepth,
                                      frame: { $0.frame }, children: { $0.childReads += 1; return $0.kids },
                                      shouldStop: shouldStop)
    }

    // MARK: Rect filter

    func testOverlapKeepsInsidePartialAndTouchingAndDropsApartOrEmpty() {
        XCTAssertTrue(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 110, y: 110, width: 10, height: 10), inkRect: ink))
        XCTAssertTrue(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 140, y: 140, width: 100, height: 100), inkRect: ink))
        XCTAssertTrue(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 0, y: 0, width: 500, height: 500), inkRect: ink))
        XCTAssertTrue(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 150, y: 100, width: 20, height: 20), inkRect: ink))
        XCTAssertFalse(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 300, y: 300, width: 20, height: 20), inkRect: ink))
        XCTAssertFalse(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 110, y: 110, width: 0, height: 10), inkRect: ink))
        XCTAssertFalse(AccessibilityTreeWalk.frameOverlaps(.zero, inkRect: ink))
        XCTAssertFalse(AccessibilityTreeWalk.frameOverlaps(.null, inkRect: ink))
    }

    func testFlatInkRectStillMatches() {
        let line = CGRect(x: 100, y: 120, width: 80, height: 0)
        XCTAssertTrue(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 90, y: 100, width: 40, height: 40), inkRect: line))
        XCTAssertFalse(AccessibilityTreeWalk.frameOverlaps(CGRect(x: 90, y: 130, width: 40, height: 40), inkRect: line))
    }

    // MARK: Walk

    func testKeepsOnlyOverlappingNodesAndSkipsSubtreesThatMissTheInk() {
        let hit = Node("hit", CGRect(x: 110, y: 110, width: 20, height: 20))
        let miss = Node("miss", CGRect(x: 600, y: 600, width: 20, height: 20))
        let hiddenChild = Node("hiddenChild", CGRect(x: 110, y: 110, width: 5, height: 5))
        let farGroup = Node("farGroup", CGRect(x: 500, y: 500, width: 300, height: 300), [hiddenChild])
        let window = Node("window", CGRect(x: 0, y: 0, width: 1000, height: 800), [hit, miss, farGroup])
        let result = walk([window])
        XCTAssertEqual(result.nodes.map(\.name), ["window", "hit"])
        XCTAssertEqual(farGroup.childReads, 0)
        XCTAssertFalse(result.stoppedEarly)
    }

    func testNodeWithoutAFrameIsDescendedButNotKept() {
        let hit = Node("hit", CGRect(x: 110, y: 110, width: 20, height: 20))
        let wrapper = Node("wrapper", nil, [hit])
        let result = walk([wrapper])
        XCTAssertEqual(result.nodes.map(\.name), ["hit"])
    }

    func testDepthLimit() {
        var node = Node("leaf", CGRect(x: 100, y: 100, width: 10, height: 10))
        for index in stride(from: 8, through: 1, by: -1) {
            node = Node("level\(index)", CGRect(x: 0, y: 0, width: 1000, height: 1000), [node])
        }
        // Root is level1 at depth 0, so level7 is depth 6 and level8 and the leaf are cut.
        let result = walk([node])
        XCTAssertEqual(result.nodes.count, 7)
        XCTAssertEqual(result.nodes.last?.name, "level7")
        XCTAssertEqual(AccessibilityTreeWalk.maxDepth, 6)
    }

    func testNodeBudgetBoundsVisitsAndChildReads() {
        let rows = (0..<5000).map { Node("row\($0)", CGRect(x: 100, y: 100, width: 10, height: 10)) }
        let table = Node("table", CGRect(x: 0, y: 0, width: 1000, height: 1000), rows)
        let result = walk([table])
        XCTAssertEqual(result.visited, AccessibilityTreeWalk.maxNodes)
        XCTAssertEqual(result.nodes.count, AccessibilityTreeWalk.maxNodes)
        XCTAssertTrue(result.stoppedEarly)
        XCTAssertEqual(AccessibilityTreeWalk.maxNodes, 200)
    }

    func testBudgetIsSharedAcrossBranches() {
        let branches = (0..<10).map { branch in
            Node("b\(branch)", CGRect(x: 0, y: 0, width: 1000, height: 1000),
                 (0..<100).map { Node("b\(branch)c\($0)", CGRect(x: 100, y: 100, width: 5, height: 5)) })
        }
        let result = walk([Node("root", CGRect(x: 0, y: 0, width: 1000, height: 1000), branches)], maxNodes: 50)
        XCTAssertLessThanOrEqual(result.visited, 50)
        XCTAssertTrue(result.stoppedEarly)
    }

    func testShouldStopHaltsTheWalk() {
        var calls = 0
        let kids = (0..<20).map { Node("k\($0)", CGRect(x: 100, y: 100, width: 5, height: 5)) }
        let result = walk([Node("root", CGRect(x: 0, y: 0, width: 1000, height: 1000), kids)], shouldStop: {
            calls += 1
            return calls > 3
        })
        XCTAssertEqual(result.visited, 3)
        XCTAssertTrue(result.stoppedEarly)
    }

    func testEmptyRootsGiveEmptyResult() {
        let result = walk([])
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertEqual(result.visited, 0)
        XCTAssertFalse(result.stoppedEarly)
    }

    // MARK: Link resolver

    private func resolve(_ node: Node) -> AccessibilityLinkResolver.Resolution {
        AccessibilityLinkResolver.resolve(from: node, parent: { $0.parent }, url: { $0.url }, label: { $0.label })
    }

    func testOwnURLWins() {
        let link = Node("link", nil)
        link.url = "https://example.com/a"
        let parent = Node("parent", nil, [link])
        parent.url = "https://example.com/other"
        XCTAssertEqual(resolve(link), .init(url: "https://example.com/a", linkedFrom: nil))
    }

    func testAncestorURLWithinThreeLevels() {
        let link = Node("link", nil)
        let l1 = Node("l1", nil, [link])
        let l2 = Node("l2", nil, [l1])
        let l3 = Node("l3", nil, [l2])
        l3.url = "https://example.com/card"
        XCTAssertEqual(resolve(link).url, "https://example.com/card")
    }

    func testAncestorURLFourLevelsUpIsNotReachedAndNearestLabelIsNoted() {
        let link = Node("link", nil)
        let l1 = Node("l1", nil, [link])
        let l2 = Node("l2", nil, [l1])
        l2.label = "group \"Navigation\""
        let l3 = Node("l3", nil, [l2])
        let l4 = Node("l4", nil, [l3])
        l4.url = "https://example.com/too-far"
        XCTAssertEqual(resolve(link), .init(url: nil, linkedFrom: "group \"Navigation\""))
    }

    func testNothingFoundGivesEmptyResolution() {
        let link = Node("link", nil, [])
        _ = Node("parent", nil, [link])
        XCTAssertEqual(resolve(link), .init(url: nil, linkedFrom: nil))
    }

    func testAtMostThreeParentReads() {
        var reads = 0
        let result = AccessibilityLinkResolver.resolve(from: 0, parent: { reads += 1; return $0 + 1 },
                                                       url: { _ in nil }, label: { _ in nil })
        XCTAssertEqual(reads, 3)
        XCTAssertNil(result.url)
    }

    func testBlankURLCountsAsNone() {
        let link = Node("link", nil)
        link.url = "  "
        XCTAssertNil(resolve(link).url)
    }
}
