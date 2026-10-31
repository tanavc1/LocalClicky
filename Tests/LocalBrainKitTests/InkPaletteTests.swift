import XCTest
@testable import LocalBrainKit

final class InkPaletteTests: XCTestCase {
    // MARK: - Helpers

    private func resolve(_ preset: InkPreset = .standard,
                         contrast: Bool = false,
                         differentiate: Bool = false,
                         reduceMotion: Bool = false,
                         scale: Double = 1) -> ResolvedInkStyle {
        InkPalette.resolve(preset: preset, increaseContrast: contrast,
                           differentiateWithoutColor: differentiate,
                           reduceMotion: reduceMotion, pointsToPixelsScale: scale)
    }

    private func hex(_ layer: InkStrokeLayer) -> UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(layer.red) << 16 | byte(layer.green) << 8 | byte(layer.blue)
    }

    private func spec(_ style: InkStyle) -> [(UInt32, Double)] {
        style.layers.map { (hex($0), $0.width) }
    }

    private func assertLayers(_ style: InkStyle, _ expected: [(UInt32, Double)],
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = spec(style)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.0, e.0, "hex \(String(a.0, radix: 16)) vs \(String(e.0, radix: 16))", file: file, line: line)
            XCTAssertEqual(a.1, e.1, accuracy: 1e-9, file: file, line: line)
        }
    }

    private let allPresets = InkPreset.allCases
    private let flags = [false, true]

    // MARK: - Default preset

    func testDefaultUserInk() {
        assertLayers(resolve().userInk, [(0xFFFFFF, 10), (0x0B0B0F, 7), (0xF0E442, 4)])
    }

    func testDefaultUserInkIncreaseContrast() {
        assertLayers(resolve(contrast: true).userInk, [(0xFFFFFF, 13), (0x000000, 9), (0xFFE100, 5)])
    }

    func testDefaultAssistantMark() {
        assertLayers(resolve().assistantMark, [(0xFFFFFF, 8), (0x0B0B0F, 5.5), (0x3380FF, 3)])
    }

    func testDefaultAssistantMarkIncreaseContrast() {
        assertLayers(resolve(contrast: true).assistantMark, [(0xFFFFFF, 12), (0x000000, 8), (0x4D94FF, 4)])
    }

    func testCursorOutline() {
        let normal = resolve().cursorOutline
        XCTAssertEqual(hex(normal.inner), 0x0B0B0F)
        XCTAssertEqual(normal.inner.width, 1)
        XCTAssertEqual(hex(normal.outer), 0xFFFFFF)
        XCTAssertEqual(normal.outer.width, 1)

        let high = resolve(contrast: true).cursorOutline
        XCTAssertEqual(hex(high.inner), 0x000000)
        XCTAssertEqual(high.inner.width, 1.5)
        XCTAssertEqual(hex(high.outer), 0xFFFFFF)
        XCTAssertEqual(high.outer.width, 1.5)
    }

    // MARK: - Other presets

    func testClassicRedChangesOnlyTheUserCore() {
        let red = resolve(.classicRed)
        let base = resolve(.standard)
        assertLayers(red.userInk, [(0xFFFFFF, 10), (0x0B0B0F, 7), (0xFF4D4D, 4)])
        XCTAssertEqual(red.assistantMark, base.assistantMark)
        XCTAssertEqual(red.cursorOutline, base.cursorOutline)
        XCTAssertEqual(red.userColourName, "red")
    }

    func testClassicRedIncreaseContrastUsesWiderGeometry() {
        assertLayers(resolve(.classicRed, contrast: true).userInk, [(0xFFFFFF, 13), (0x000000, 9), (0xFF4D4D, 5)])
    }

    func testMonochrome() {
        let mono = resolve(.monochrome)
        assertLayers(mono.userInk, [(0xFFFFFF, 10), (0x0B0B0F, 7), (0xFFFFFF, 4)])
        assertLayers(mono.assistantMark, [(0xFFFFFF, 8), (0x0B0B0F, 5.5), (0x8C8C8C, 3)])
        XCTAssertEqual(mono.userColourName, "white")
    }

    func testMonochromeIncreaseContrastOnlyWidensAndDarkens() {
        let mono = resolve(.monochrome, contrast: true)
        assertLayers(mono.userInk, [(0xFFFFFF, 13), (0x000000, 9), (0xFFFFFF, 5)])
        assertLayers(mono.assistantMark, [(0xFFFFFF, 12), (0x000000, 8), (0x8C8C8C, 4)])
    }

    func testHighVisibilityIsTheIncreaseContrastLookRegardlessOfTheFlag() {
        let off = resolve(.highVisibility, contrast: false)
        let on = resolve(.highVisibility, contrast: true)
        XCTAssertEqual(off, on)
        XCTAssertEqual(off.userInk, resolve(.standard, contrast: true).userInk)
        XCTAssertEqual(off.assistantMark, resolve(.standard, contrast: true).assistantMark)
        XCTAssertEqual(off.cursorOutline, resolve(.standard, contrast: true).cursorOutline)
        XCTAssertEqual(off.userColourName, "yellow")
    }

    func testHighVisibilityIsAlwaysDashed() {
        for contrast in flags {
            for differentiate in flags {
                XCTAssertTrue(resolve(.highVisibility, contrast: contrast, differentiate: differentiate).assistantDashed)
            }
        }
    }

    // MARK: - Dash flag

    func testDashFollowsDifferentiateWithoutColourForOtherPresets() {
        for preset in [InkPreset.standard, .classicRed, .monochrome] {
            XCTAssertFalse(resolve(preset, differentiate: false).assistantDashed, "\(preset)")
            XCTAssertTrue(resolve(preset, differentiate: true).assistantDashed, "\(preset)")
        }
    }

    func testDashPatternIsEightOnFiveOff() {
        XCTAssertEqual(resolve().assistantDashPattern, [8, 5])
        XCTAssertEqual(resolve(scale: 0.5).assistantDashPattern, [4, 2.5])
    }

    // MARK: - Fade timings

    func testFadeTimings() {
        XCTAssertEqual(resolve().fade, InkFadeTimings(hold: 1.5, fade: 0.5))
        XCTAssertEqual(resolve(reduceMotion: true).fade, InkFadeTimings(hold: 1.5, fade: 0.25))
    }

    func testReduceMotionChangesOnlyTheFade() {
        for preset in allPresets {
            for contrast in flags {
                for differentiate in flags {
                    var calm = resolve(preset, contrast: contrast, differentiate: differentiate, reduceMotion: true)
                    let normal = resolve(preset, contrast: contrast, differentiate: differentiate, reduceMotion: false)
                    XCTAssertNotEqual(calm.fade, normal.fade)
                    calm.fade = normal.fade
                    XCTAssertEqual(calm, normal)
                }
            }
        }
    }

    // MARK: - Every combination

    func testIncreaseContrastChangesOutputForEveryPresetButHighVisibility() {
        for preset in allPresets {
            let off = resolve(preset, contrast: false)
            let on = resolve(preset, contrast: true)
            if preset == .highVisibility {
                XCTAssertEqual(off, on)
            } else {
                XCTAssertNotEqual(off.userInk, on.userInk, "\(preset)")
                XCTAssertNotEqual(off.assistantMark, on.assistantMark, "\(preset)")
                XCTAssertNotEqual(off.cursorOutline, on.cursorOutline, "\(preset)")
            }
        }
    }

    func testDifferentiateChangesOnlyTheDashFlag() {
        for preset in allPresets where preset != .highVisibility {
            for contrast in flags {
                var withCue = resolve(preset, contrast: contrast, differentiate: true)
                let without = resolve(preset, contrast: contrast, differentiate: false)
                XCTAssertTrue(withCue.assistantDashed)
                XCTAssertFalse(without.assistantDashed)
                withCue.assistantDashed = false
                XCTAssertEqual(withCue, without)
            }
        }
    }

    func testPresetsAreVisuallyDistinct() {
        let cores = allPresets.map { hex(resolve($0).userInk.layers[2]) }
        XCTAssertEqual(Set(cores).count, allPresets.count)
        XCTAssertNotEqual(resolve(.standard).userInk, resolve(.highVisibility).userInk)
    }

    func testAlphaIsOneOnEveryLayerOfEveryCombination() {
        for preset in allPresets {
            for contrast in flags {
                for differentiate in flags {
                    for reduceMotion in flags {
                        let style = resolve(preset, contrast: contrast, differentiate: differentiate,
                                            reduceMotion: reduceMotion, scale: 0.77)
                        let all = style.userInk.layers + style.userPenTip.layers + style.assistantMark.layers
                            + [style.cursorOutline.inner, style.cursorOutline.outer]
                        for layer in all { XCTAssertEqual(layer.alpha, 1.0, "\(preset)") }
                    }
                }
            }
        }
    }

    func testLayerOrderIsWhiteCasingThenDarkCasingThenCore() {
        for preset in allPresets {
            for contrast in flags {
                let style = resolve(preset, contrast: contrast)
                for ink in [style.userInk, style.userPenTip, style.assistantMark] {
                    XCTAssertEqual(ink.layers.count, 3)
                    XCTAssertEqual(hex(ink.layers[0]), 0xFFFFFF)
                    XCTAssertTrue([0x0B0B0F, 0x000000].contains(hex(ink.layers[1])))
                    XCTAssertGreaterThan(ink.layers[0].width, ink.layers[1].width)
                    XCTAssertGreaterThan(ink.layers[1].width, ink.layers[2].width)
                }
            }
        }
    }

    // MARK: - Scale and pen tip

    func testWidthsScaleWithPointsToPixels() {
        let scaled = resolve(scale: 0.75)
        assertLayers(scaled.userInk, [(0xFFFFFF, 7.5), (0x0B0B0F, 5.25), (0xF0E442, 3)])
        XCTAssertEqual(scaled.cursorOutline.inner.width, 0.75, accuracy: 1e-9)
    }

    func testScaleDoesNotChangeColours() {
        let small = resolve(scale: 0.5).userInk.layers.map(hex)
        let large = resolve(scale: 2).userInk.layers.map(hex)
        XCTAssertEqual(small, large)
    }

    func testPenTipIsASixPointCoreWithTheTrailsCasingMargins() {
        assertLayers(resolve().userPenTip, [(0xFFFFFF, 12), (0x0B0B0F, 9), (0xF0E442, 6)])
        assertLayers(resolve(contrast: true).userPenTip, [(0xFFFFFF, 14), (0x000000, 10), (0xFFE100, 6)])
    }

    func testPenTipDotIsWiderThanTheTrailCore() {
        let style = resolve()
        XCTAssertGreaterThan(style.userPenTip.layers[2].width, style.userInk.layers[2].width)
    }
}
