import XCTest
@testable import LocalBrainKit

final class SketchTemplateTests: XCTestCase {
    private let sizes = [(1152, 720), (1152, 749), (1152, 648), (720, 1152)]

    private func shape(_ drawing: InkDrawing) -> ShapeTag {
        guard case .shape(let tag) = drawing else { fatalError("a sketch holds shapes only") }
        return tag
    }

    private func ticTacToe(_ board: String = SketchTemplate.demoBoard, width: Int = 1152, height: Int = 720,
                           anchor: SketchAnchor = .centre, size: SketchSize = .normal) -> SketchPlan {
        SketchTemplate.plan(.ticTacToe, imageWidth: width, imageHeight: height, anchor: anchor, size: size, board: board)!
    }

    func testTicTacToeIsAGridThenTheMovesInPlayOrder() {
        let kinds = ticTacToe().drawings.map { shape($0).kind }
        XCTAssertEqual(kinds, [.line, .line, .line, .line, .line, .line, .circle, .line, .line])
    }

    func testTheGridIsASquareOfHalfTheShorterSideInTheMiddle() {
        let lines = ticTacToe().drawings.prefix(4).map { shape($0).points }
        // 1152x720: a 360 px board, cells of 120 px, centred.
        XCTAssertEqual(lines[0], [CGPoint(x: 516, y: 180), CGPoint(x: 516, y: 540)])
        XCTAssertEqual(lines[1], [CGPoint(x: 636, y: 180), CGPoint(x: 636, y: 540)])
        XCTAssertEqual(lines[2], [CGPoint(x: 396, y: 300), CGPoint(x: 756, y: 300)])
        XCTAssertEqual(lines[3], [CGPoint(x: 396, y: 420), CGPoint(x: 756, y: 420)])
    }

    func testTheVerticalsSitAtThirdsOfTheHorizontalsSpan() {
        for (width, height) in sizes {
            let lines = ticTacToe(width: width, height: height).drawings.prefix(4).map { shape($0).points }
            let left = lines[2][0].x, right = lines[2][1].x
            XCTAssertEqual(lines[0][0].x, left + (right - left) / 3, accuracy: 0.5)
            XCTAssertEqual(lines[1][0].x, left + 2 * (right - left) / 3, accuracy: 0.5)
            let top = lines[0][0].y, bottom = lines[0][1].y
            XCTAssertEqual(lines[2][0].y, top + (bottom - top) / 3, accuracy: 0.5)
            XCTAssertEqual(lines[3][0].y, top + 2 * (bottom - top) / 3, accuracy: 0.5)
        }
    }

    func testEachXStaysInsideItsCellAndTheOHasItsRingPointRightOfItsCentre() {
        let drawings = ticTacToe().drawings
        let cell = CGRect(x: 396, y: 180, width: 120, height: 120)   // top left
        let centreCell = CGRect(x: 516, y: 300, width: 120, height: 120)
        let bottomRight = CGRect(x: 636, y: 420, width: 120, height: 120)
        for (indices, rect) in [([4, 5], centreCell), ([7, 8], bottomRight)] {
            for index in indices {
                for point in shape(drawings[index]).points { XCTAssertTrue(rect.contains(point), "\(index) \(point)") }
            }
        }
        let ring = shape(drawings[6])
        XCTAssertEqual(ring.kind, .circle)
        XCTAssertTrue(cell.contains(ring.points[0]))
        XCTAssertTrue(cell.contains(ring.points[1]))
        XCTAssertGreaterThan(ring.points[1].x, ring.points[0].x)
        XCTAssertEqual(ring.points[1].y, ring.points[0].y)
    }

    func testEveryPointIsInsideTheImageForEveryFigureAndSize() {
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for (width, height) in sizes {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            for figure in figures {
                let plan = SketchTemplate.plan(figure, imageWidth: width, imageHeight: height, board: "XOXOXOXOX")!
                XCTAssertFalse(plan.drawings.isEmpty)
                for drawing in plan.drawings {
                    for point in shape(drawing).points {
                        XCTAssertTrue(frame.contains(point), "\(figure) \(width)x\(height) \(point)")
                    }
                }
            }
        }
    }

    func testAnEmptyBoardIsJustTheGrid() {
        XCTAssertEqual(ticTacToe("....").drawings.count, 4)
        XCTAssertEqual(ticTacToe(".........").drawings.count, 4)
        XCTAssertEqual(ticTacToe("....").spokenSentence, "here is an empty tic tac toe board in the middle of your screen.")
    }

    func testTheSentenceNamesEveryMoveByItsCell() {
        XCTAssertEqual(ticTacToe().spokenSentence,
                       "here is a tic tac toe board in the middle of your screen, with an x in the centre, an o in the top left and an x in the bottom right.")
        XCTAssertEqual(ticTacToe("....X....").spokenSentence,
                       "here is a tic tac toe board in the middle of your screen, with an x in the centre.")
    }

    func testSmileyHasAFaceTwoEyesAndAMouthBelowTheEyes() {
        let drawings = SketchTemplate.plan(.smiley, imageWidth: 1152, imageHeight: 720)!.drawings
        XCTAssertEqual(drawings.map { shape($0).kind }, [.circle, .circle, .circle, .curve])
        let eyeY = shape(drawings[1]).points[0].y
        for point in shape(drawings[3]).points { XCTAssertGreaterThan(point.y, eyeY) }
    }

    func testEverySentenceNamesTheFigureAndIsLowercaseWithoutDashes() {
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for figure in figures {
            let sentence = SketchTemplate.plan(figure, imageWidth: 1152, imageHeight: 720)!.spokenSentence
            XCTAssertTrue(sentence.hasPrefix("here is a"), sentence)
            XCTAssertEqual(sentence, sentence.lowercased())
            XCTAssertFalse(sentence.contains("\u{2014}"))
        }
        XCTAssertFalse(SketchTemplate.unsupportedSentence.contains("\u{2014}"))
    }

    func testNoPlanForAFreeformFigure() {
        XCTAssertNil(SketchTemplate.plan(.freeform("house"), imageWidth: 1152, imageHeight: 720))
    }

    // showMarks skips a drawing whose geometry is empty without a word, so pin that no template is one.
    func testEveryTemplateDrawingBuildsNonEmptyGeometry() {
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for (width, height) in sizes {
            let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        displayWidthInPoints: 1440, displayHeightInPoints: 900,
                                        screenshotWidthInPixels: width, screenshotHeightInPixels: height)
            for figure in figures {
                let plan = SketchTemplate.plan(figure, imageWidth: width, imageHeight: height, board: "XOXOXOXOX")!
                for drawing in plan.drawings {
                    let geometry = MarkGeometryBuilder.geometry(for: MarkGeometryBuilder.overlayDrawing(from: drawing, mapping: mapping))
                    XCTAssertTrue(geometry.passes.contains { pass in pass.contains { !$0.points.isEmpty } },
                                  "\(figure) \(width)x\(height)")
                }
            }
        }
    }

    func testFreeformSpeechIsTheModelsWordsOrAnHonestFallback() {
        let tag = "[SHAPE:line:200,200;800,200]"
        // Words after the tags are spoken, tags removed.
        XCTAssertEqual(SketchLimits.spokenSentence(in: tag + "\n" + tag + "\nhere is a line.", closedTags: 2), "here is a line.")
        // Tags but no sentence: a sentence is still spoken.
        XCTAssertEqual(SketchLimits.spokenSentence(in: tag + "\n" + tag, closedTags: 2), SketchLimits.drawnSentence)
        // A tag cut off by the token cap is dropped, not read out.
        XCTAssertEqual(SketchLimits.spokenSentence(in: tag + "\n[SHAPE:line:200,300;8", closedTags: 1), SketchLimits.drawnSentence)
        XCTAssertEqual(SketchLimits.spokenSentence(in: tag + " here is a line.\n[SHAPE:line:200,300;8", closedTags: 1), "here is a line.")
        // No valid tag: the failure sentence, whatever the model said.
        XCTAssertEqual(SketchLimits.spokenSentence(in: "i cannot do that", closedTags: 0), SketchLimits.failureSentence)
        XCTAssertEqual(SketchLimits.drawnSentence, SketchLimits.drawnSentence.lowercased())
        XCTAssertFalse(SketchLimits.drawnSentence.contains("\u{2014}"))
    }

    func testAFreeformSketchAdmitsShapesUpToTheCapAndNoHighlights() {
        let shapeTag = ShapeTag(kind: .line, points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)], label: nil, screenNumber: nil)
        let highlight = HighlightTag(rect: CGRect(x: 1, y: 1, width: 5, height: 5), label: nil, screenNumber: nil)
        XCTAssertEqual(SketchLimits.maxTags, 8)
        XCTAssertTrue(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 0))
        XCTAssertTrue(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 7))
        XCTAssertFalse(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 8))
        XCTAssertFalse(SketchLimits.admits(.highlight(highlight), alreadyClosed: 0))
    }

    func testTheSketchHoldIsTenSecondsAndTheSentencesAreSpeakable() {
        XCTAssertEqual(SketchTiming.holdSeconds, 10)
        XCTAssertEqual(SketchLimits.failureSentence, "i could not draw that one.")
        XCTAssertEqual(SketchLimits.freeformAnswerMaxTokens, 400)
    }

    func testTheArrowPointsUp() {
        let points = shape(SketchTemplate.plan(.arrow, imageWidth: 1152, imageHeight: 720)!.drawings[0]).points
        XCTAssertLessThan(points[1].y, points[0].y)
    }

    // MARK: placement

    private let allFigures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]

    private func bounds(_ plan: SketchPlan) -> CGRect {
        // A circle's second point is on the ring, so the ring's extent is the point's distance from its centre.
        var rect = CGRect.null
        for drawing in plan.drawings {
            let tag = shape(drawing)
            if tag.kind == .circle {
                let r = abs(tag.points[1].x - tag.points[0].x)
                rect = rect.union(CGRect(x: tag.points[0].x - r, y: tag.points[0].y - r, width: 2 * r, height: 2 * r))
            } else {
                for point in tag.points { rect = rect.union(CGRect(origin: point, size: .zero)) }
            }
        }
        return rect
    }

    func testEveryFigureStaysFullyOnTheScreenInEveryRegionAtEverySize() {
        for (width, height) in sizes {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            for anchor in SketchAnchor.allCases {
                for size in [SketchSize.small, .normal, .large] {
                    for figure in allFigures {
                        let plan = SketchTemplate.plan(figure, imageWidth: width, imageHeight: height, anchor: anchor, size: size,
                                                       board: "XOXOXOXOX")!
                        let box = bounds(plan)
                        XCTAssertTrue(frame.contains(box), "\(figure) \(anchor) \(size) \(width)x\(height) \(box)")
                    }
                }
            }
        }
    }

    func testEachFigureIsCentredInItsThirdOfTheScreen() {
        for (width, height) in sizes {
            for anchor in SketchAnchor.allCases {
                for figure in allFigures {
                    let box = bounds(SketchTemplate.plan(figure, imageWidth: width, imageHeight: height, anchor: anchor)!)
                    let thirdWidth = Double(width) / 3, thirdHeight = Double(height) / 3
                    let third = CGRect(x: Double(anchor.column) * thirdWidth, y: Double(anchor.row) * thirdHeight,
                                       width: thirdWidth, height: thirdHeight)
                    XCTAssertTrue(third.contains(CGPoint(x: box.midX, y: box.midY)), "\(figure) \(anchor) \(width)x\(height)")
                }
            }
        }
    }

    func testTheCentreRegionAndTheNormalSizeAreTheOldPlacement() {
        let old = ticTacToe(anchor: .centre, size: .normal)
        let lines = old.drawings.prefix(4).map { shape($0).points }
        XCTAssertEqual(lines[0], [CGPoint(x: 516, y: 180), CGPoint(x: 516, y: 540)])
    }

    func testBiggerAndSmallerFiguresScaleAboutTheirCentre() {
        let small = bounds(SketchTemplate.plan(.circle, imageWidth: 1152, imageHeight: 720, size: .small)!)
        let normal = bounds(SketchTemplate.plan(.circle, imageWidth: 1152, imageHeight: 720)!)
        let large = bounds(SketchTemplate.plan(.circle, imageWidth: 1152, imageHeight: 720, size: .large)!)
        XCTAssertLessThan(small.width, normal.width)
        XCTAssertGreaterThan(large.width, normal.width)
        XCTAssertEqual(small.midX, normal.midX, accuracy: 0.5)
        XCTAssertEqual(large.midY, normal.midY, accuracy: 0.5)
    }

    func testTheSentenceNamesTheRealPosition() {
        func sentence(_ figure: SketchFigure, _ anchor: SketchAnchor) -> String {
            SketchTemplate.plan(figure, imageWidth: 1152, imageHeight: 720, anchor: anchor)!.spokenSentence
        }
        XCTAssertEqual(sentence(.star, .centre), "here is a star in the middle of your screen.")
        XCTAssertEqual(sentence(.star, .bottomLeft), "here is a star in the bottom left of your screen.")
        XCTAssertEqual(sentence(.box, .topRight), "here is a square box in the top right of your screen.")
        XCTAssertEqual(sentence(.circle, .top), "here is a circle at the top of your screen.")
        XCTAssertEqual(sentence(.circle, .left), "here is a circle on the left of your screen.")
        XCTAssertEqual(sentence(.arrow, .bottom), "here is an arrow at the bottom of your screen, pointing up.")
        XCTAssertEqual(sentence(.line, .centre), "here is a straight line across the middle of your screen.")
        XCTAssertEqual(sentence(.line, .right), "here is a straight line on the right of your screen.")
        XCTAssertEqual(SketchTemplate.plan(.ticTacToe, imageWidth: 1152, imageHeight: 720, anchor: .bottomLeft)!.spokenSentence,
                       "here is an empty tic tac toe board in the bottom left of your screen.")
        XCTAssertEqual(SketchTemplate.plan(.ticTacToe, imageWidth: 1152, imageHeight: 720, anchor: .bottomLeft, board: "....X....")!.spokenSentence,
                       "here is a tic tac toe board in the bottom left of your screen, with an x in the centre.")
        for anchor in SketchAnchor.allCases {
            for figure in allFigures {
                let text = sentence(figure, anchor)
                XCTAssertTrue(text.contains("your screen"), text)
                XCTAssertFalse(text.contains("\u{2014}"))
            }
        }
    }

    func testThePlainRequestDrawsAnEmptyBoardAndTheSentenceSaysSo() {
        let plan = SketchTemplate.plan(.ticTacToe, imageWidth: 1152, imageHeight: 720)!
        XCTAssertEqual(plan.drawings.count, 4)
        XCTAssertEqual(plan.spokenSentence, "here is an empty tic tac toe board in the middle of your screen.")
        XCTAssertEqual(SketchTemplate.emptyBoard.count, 9)
        XCTAssertEqual(SketchTemplate.demoBoard, "O...X...X")
    }

    func testTheSentenceDescribesExactlyTheMovesDrawn() {
        // x centre, o top left, x top right: 3 moves, x first, 2 + 1 + 2 strokes after the grid.
        let board = "O.X.X...."
        let plan = ticTacToe(board)
        XCTAssertEqual(plan.drawings.count, 4 + 2 + 1 + 2)
        XCTAssertEqual(plan.spokenSentence,
                       "here is a tic tac toe board in the middle of your screen, with an x in the top right, an o in the top left and an x in the centre.")
    }
}
