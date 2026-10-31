import XCTest
import CoreGraphics
import ImageIO
@testable import LocalBrainKit

final class InkImageTests: XCTestCase {
    private let resolvedStyle = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                                   differentiateWithoutColor: false, reduceMotion: false).userInk

    // MARK: - Synthetic image helpers

    private func makeJPEG(width: Int, height: Int, gray: CGFloat = 0.5) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        /// (r, g, b) at a top-left-origin pixel.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
    }

    private func decodePixels(_ data: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    private let solidRed = InkStyle(layers: [InkStrokeLayer(red: 1, green: 0, blue: 0, alpha: 1, width: 6)])

    // MARK: - compositeInk

    func testCompositeKeepsPixelSize() throws {
        let source = makeJPEG(width: 400, height: 300)
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source,
                                                      strokesInImagePixels: [[CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)]],
                                                      style: solidRed))
        let pixels = try XCTUnwrap(decodePixels(out))
        XCTAssertEqual(pixels.width, 400)
        XCTAssertEqual(pixels.height, 300)
    }

    func testPixelsUnderTheStrokeChangeAndOthersDoNot() throws {
        let source = makeJPEG(width: 400, height: 300)
        let before = try XCTUnwrap(decodePixels(source))
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source,
                                                      strokesInImagePixels: [[CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)]],
                                                      style: solidRed))
        let after = try XCTUnwrap(decodePixels(out))

        let onStroke = after.rgb(200, 150)
        XCTAssertGreaterThan(onStroke.0, 200)
        XCTAssertLessThan(onStroke.1, 80)
        XCTAssertLessThan(onStroke.2, 80)

        for (x, y) in [(200, 20), (200, 280), (10, 150), (390, 150), (200, 140), (200, 160)] {
            let a = before.rgb(x, y), b = after.rgb(x, y)
            XCTAssertLessThanOrEqual(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2), 12, "pixel \(x),\(y)")
        }
    }

    func testStrokeUsesTopLeftOrigin() throws {
        // A stroke near the top must change the top rows, not the bottom ones.
        let source = makeJPEG(width: 300, height: 200)
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source,
                                                      strokesInImagePixels: [[CGPoint(x: 40, y: 20), CGPoint(x: 260, y: 20)]],
                                                      style: solidRed))
        let after = try XCTUnwrap(decodePixels(out))
        XCTAssertGreaterThan(after.rgb(150, 20).0, 200)
        XCTAssertLessThan(after.rgb(150, 20).1, 80)
        XCTAssertLessThan(abs(after.rgb(150, 180).0 - 128), 12)
        XCTAssertLessThan(abs(after.rgb(150, 180).1 - 128), 12)
    }

    func testCasingLayerIsDrawnUnderTheCore() throws {
        let style = InkStyle(layers: [InkStrokeLayer(red: 1, green: 1, blue: 1, alpha: 1, width: 24),
                                      InkStrokeLayer(red: 1, green: 0, blue: 0, alpha: 1, width: 4)])
        let source = makeJPEG(width: 400, height: 300, gray: 0.2)
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source,
                                                      strokesInImagePixels: [[CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)]],
                                                      style: style))
        let after = try XCTUnwrap(decodePixels(out))
        let core = after.rgb(200, 150)
        let casing = after.rgb(200, 157)
        XCTAssertGreaterThan(core.0, 200); XCTAssertLessThan(core.1, 90)
        XCTAssertGreaterThan(casing.0, 200); XCTAssertGreaterThan(casing.1, 200); XCTAssertGreaterThan(casing.2, 200)
        XCTAssertLessThan(after.rgb(200, 185).0, 90)
    }

    func testSinglePointDrawsADot() throws {
        let source = makeJPEG(width: 200, height: 200)
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source, strokesInImagePixels: [[CGPoint(x: 100, y: 100)]],
                                                      style: solidRed))
        let after = try XCTUnwrap(decodePixels(out))
        XCTAssertGreaterThan(after.rgb(100, 100).0, 200)
        XCTAssertLessThan(after.rgb(100, 100).1, 80)
    }

    func testNoStrokesStillReturnsSameSizeJPEG() throws {
        let source = makeJPEG(width: 120, height: 90)
        let out = try XCTUnwrap(InkImage.compositeInk(jpegData: source, strokesInImagePixels: [], style: resolvedStyle))
        let pixels = try XCTUnwrap(decodePixels(out))
        XCTAssertEqual(pixels.width, 120)
        XCTAssertEqual(pixels.height, 90)
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(InkImage.compositeInk(jpegData: Data([1, 2, 3]), strokesInImagePixels: [], style: resolvedStyle))
        XCTAssertNil(InkImage.cropAround(jpegData: Data([1, 2, 3]), rectInImagePixels: .zero))
    }

    // MARK: - crop rect math

    private let image = CGSize(width: 1152, height: 748)

    func testCropRectPadsByTwentyPercentPerSide() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: 400, y: 300, width: 200, height: 200),
                                     imageSize: image, padding: 0.2, minSide: 100)
        XCTAssertEqual(rect, CGRect(x: 360, y: 260, width: 280, height: 280))
    }

    func testTinyCircleGetsTheMinimumSideAroundItsCentre() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: 500, y: 400, width: 20, height: 20),
                                     imageSize: image, padding: 0.2, minSide: 320)
        XCTAssertEqual(rect.width, 320)
        XCTAssertEqual(rect.height, 320)
        XCTAssertEqual(rect.midX, 510, accuracy: 1)
        XCTAssertEqual(rect.midY, 410, accuracy: 1)
    }

    func testHorizontalLineWithZeroHeightStillGetsContext() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: 100, y: 300, width: 600, height: 0),
                                     imageSize: image, padding: 0.2, minSide: 320)
        XCTAssertEqual(rect.height, 320)
        XCTAssertEqual(rect.width, 840)
    }

    func testCropShiftsInsideTheImageKeepingItsSize() {
        let nearCorner = InkImage.cropRect(forInkBounds: CGRect(x: 0, y: 0, width: 20, height: 20),
                                           imageSize: image, padding: 0.2, minSide: 320)
        XCTAssertEqual(nearCorner, CGRect(x: 0, y: 0, width: 320, height: 320))
        let farCorner = InkImage.cropRect(forInkBounds: CGRect(x: 1140, y: 740, width: 12, height: 8),
                                          imageSize: image, padding: 0.2, minSide: 320)
        XCTAssertEqual(farCorner, CGRect(x: 832, y: 428, width: 320, height: 320))
    }

    func testCropClampsToTheWholeImageWhenTooBig() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: -50, y: -50, width: 2000, height: 1500),
                                     imageSize: image, padding: 0.2, minSide: 320)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1152, height: 748))
    }

    func testMinSideLargerThanImageClampsToImage() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: 10, y: 10, width: 10, height: 10),
                                     imageSize: CGSize(width: 200, height: 150), padding: 0.2, minSide: 320)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    func testCropRectIsIntegralAndInsideTheImage() {
        let rect = InkImage.cropRect(forInkBounds: CGRect(x: 333.3, y: 201.7, width: 77.7, height: 41.1),
                                     imageSize: image, padding: 0.2, minSide: 100)
        XCTAssertEqual(rect, rect.integral)
        XCTAssertTrue(CGRect(origin: .zero, size: image).contains(rect))
    }

    // MARK: - cropAround on real data

    func testCropAroundReturnsThePaddedRegion() throws {
        let source = makeJPEG(width: 800, height: 600)
        let crop = try XCTUnwrap(InkImage.cropAround(jpegData: source,
                                                     rectInImagePixels: CGRect(x: 300, y: 200, width: 100, height: 100),
                                                     padding: 0.2, minSide: 150, maxLongEdge: 2000))
        XCTAssertEqual(crop.rectInImagePixels, CGRect(x: 275, y: 175, width: 150, height: 150))
        let pixels = try XCTUnwrap(decodePixels(crop.jpegData))
        XCTAssertEqual(pixels.width, 150)
        XCTAssertEqual(pixels.height, 150)
        XCTAssertEqual(crop.outputSize, CGSize(width: 150, height: 150))
    }

    func testCropAroundScalesDownToMaxLongEdge() throws {
        let source = makeJPEG(width: 1600, height: 1000)
        let crop = try XCTUnwrap(InkImage.cropAround(jpegData: source,
                                                     rectInImagePixels: CGRect(x: 100, y: 100, width: 1000, height: 500),
                                                     padding: 0, minSide: 100, maxLongEdge: 500))
        XCTAssertEqual(crop.rectInImagePixels, CGRect(x: 100, y: 100, width: 1000, height: 500))
        let pixels = try XCTUnwrap(decodePixels(crop.jpegData))
        XCTAssertEqual(pixels.width, 500)
        XCTAssertEqual(pixels.height, 250)
    }

    func testCropKeepsTheInkThatWasCompositedInside() throws {
        let source = makeJPEG(width: 800, height: 600)
        let stroke = [CGPoint(x: 380, y: 300), CGPoint(x: 420, y: 300)]
        let inked = try XCTUnwrap(InkImage.compositeInk(jpegData: source, strokesInImagePixels: [stroke], style: solidRed))
        let crop = try XCTUnwrap(InkImage.cropAround(jpegData: inked,
                                                     rectInImagePixels: CGRect(x: 380, y: 300, width: 40, height: 0),
                                                     padding: 0.2, minSide: 200, maxLongEdge: 1000))
        let pixels = try XCTUnwrap(decodePixels(crop.jpegData))
        let localX = Int(400 - crop.rectInImagePixels.minX)
        let localY = Int(300 - crop.rectInImagePixels.minY)
        XCTAssertGreaterThan(pixels.rgb(localX, localY).0, 200)
        XCTAssertLessThan(pixels.rgb(localX, localY).1, 80)
    }

    // MARK: - Minimum core width

    private func assertWidths(_ style: InkStyle, _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(style.layers.count, expected.count, file: file, line: line)
        for (layer, width) in zip(style.layers, expected) {
            XCTAssertEqual(layer.width, width, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testMinimumCoreWidthScalesEveryLayerByTheSameFactor() {
        let external = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                          differentiateWithoutColor: false, reduceMotion: false,
                                          pointsToPixelsScale: 0.45).userInk
        // Before: white 4.5, dark 3.15, core 1.8 px. The core is raised to 3, so x 5/3.
        assertWidths(external, [4.5, 3.15, 1.8])
        let floored = external.withMinimumCoreWidth(3)
        assertWidths(floored, [7.5, 5.25, 3.0])
        // Colours are untouched.
        XCTAssertEqual(floored.layers.map(\.red), external.layers.map(\.red))
    }

    func testMinimumCoreWidthLeavesAWideEnoughStyleAlone() {
        let builtIn = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                         differentiateWithoutColor: false, reduceMotion: false,
                                         pointsToPixelsScale: 0.76).userInk
        XCTAssertGreaterThanOrEqual(builtIn.layers.last!.width, 3)
        XCTAssertEqual(builtIn.withMinimumCoreWidth(3), builtIn)
        XCTAssertEqual(InkStyle(layers: []).withMinimumCoreWidth(3), InkStyle(layers: []))
    }

    func testTheOnScreenStyleIsNotFloored() {
        // The floor is applied to the model's copy only; the resolved style the
        // overlay draws keeps the 4 pt core at scale 1.
        let onScreen = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                          differentiateWithoutColor: false, reduceMotion: false).userInk
        XCTAssertEqual(onScreen.layers.map(\.width), [10, 7, 4])
    }
}
