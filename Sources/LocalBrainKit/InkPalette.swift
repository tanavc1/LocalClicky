//
//  InkPalette.swift
//  LocalBrainKit
//
//  The one place that decides how ink and marks look. Pure logic, no UI: the
//  overlay draws what it returns in points (scale 1), and the screenshot
//  composite draws the same style in image pixels (scale = screenshot width
//  over display width), so the model sees the ink the way the user did.
//
//  The rules come from the contrast review in the drawing spec:
//    - Every stroke is three passes on one path, painted bottom to top: a white
//      casing, a dark casing, then the core. One casing edge is always legible
//      on any background, and the core sits on the dark casing.
//    - Alpha is always 1.0. The fade animates the whole group's opacity, never
//      a layer's alpha, and there is no glow, blur or shadow.
//    - Colour is never the only cue: user ink is a smooth trail with a pen-tip
//      dot, assistant marks can be dashed, and Increase Contrast widens
//      everything.
//
//  Presets (no free colour picker):
//    Default          yellow user ink, blue assistant marks
//    Classic red      red user ink; everything else as Default
//    Monochrome       white user ink, grey assistant marks; otherwise Default
//    High visibility  the Increase Contrast look always, assistant cores dashed
//

import Foundation

public enum InkPreset: String, CaseIterable, Sendable {
    case standard
    case classicRed
    case monochrome
    case highVisibility

    public var displayName: String {
        switch self {
        case .standard: return "Default"
        case .classicRed: return "Classic red"
        case .monochrome: return "Monochrome"
        case .highVisibility: return "High visibility"
        }
    }
}

extension InkStrokeLayer {
    /// An opaque layer from a 0xRRGGBB value. `width` is already in the unit
    /// the caller draws in (points or image pixels).
    public init(rgb: UInt32, width: Double) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: 1,
                  width: width)
    }
}

/// How long the user's ink stays after the keys come up: a hold, then a fade
/// of the whole group's opacity.
public struct InkFadeTimings: Equatable, Sendable {
    public var hold: Double
    public var fade: Double

    public init(hold: Double, fade: Double) {
        self.hold = hold
        self.fade = fade
    }
}

/// The outline drawn around the blue cursor triangle. Each layer's `width` is
/// the band thickness outside the triangle edge, not a stroke width: the inner
/// band is dark, the outer band is white.
public struct InkCursorOutline: Equatable, Sendable {
    public var inner: InkStrokeLayer
    public var outer: InkStrokeLayer
}

public struct ResolvedInkStyle: Equatable, Sendable {
    /// White casing, dark casing, core.
    public var userInk: InkStyle
    /// The same three passes for a single point: the pen-tip dot at the head
    /// of the trail. Widths are diameters.
    public var userPenTip: InkStyle
    /// White casing, dark casing, core.
    public var assistantMark: InkStyle
    /// True when assistant cores are drawn dashed (casings stay solid).
    public var assistantDashed: Bool
    /// On, off lengths for the dashed core, in the same unit as the widths.
    public var assistantDashPattern: [Double]
    public var cursorOutline: InkCursorOutline
    public var fade: InkFadeTimings
    /// Plain word for the user's ink colour, for the model prompt.
    public var userColourName: String
}

public enum InkPalette {
    public static let holdSeconds: Double = 1.5
    public static let fadeSeconds: Double = 0.5
    public static let reducedMotionFadeSeconds: Double = 0.25
    /// Diameter of the pen-tip dot's core, in points.
    public static let penTipDiameter: Double = 6
    public static let dashOn: Double = 8
    public static let dashOff: Double = 5

    private static let darkCasing: UInt32 = 0x0B0B0F
    private static let darkCasingHighContrast: UInt32 = 0x000000
    private static let whiteCasing: UInt32 = 0xFFFFFF

    private struct Widths {
        var userCore, userDark, userWhite: Double
        var assistantCore, assistantDark, assistantWhite: Double
        var cursorBand: Double
    }

    private static let normalWidths = Widths(userCore: 4, userDark: 7, userWhite: 10,
                                             assistantCore: 3, assistantDark: 5.5, assistantWhite: 8,
                                             cursorBand: 1)
    private static let highContrastWidths = Widths(userCore: 5, userDark: 9, userWhite: 13,
                                                   assistantCore: 4, assistantDark: 8, assistantWhite: 12,
                                                   cursorBand: 1.5)

    public static func resolve(preset: InkPreset,
                               increaseContrast: Bool,
                               differentiateWithoutColor: Bool,
                               reduceMotion: Bool,
                               pointsToPixelsScale: Double = 1) -> ResolvedInkStyle {
        // High visibility is the Increase Contrast look whatever the system says.
        let highContrast = increaseContrast || preset == .highVisibility
        let widths = highContrast ? highContrastWidths : normalWidths
        let dark = highContrast ? darkCasingHighContrast : darkCasing

        let userCore: UInt32
        let userName: String
        let assistantCore: UInt32
        switch preset {
        case .standard, .highVisibility:
            userCore = highContrast ? 0xFFE100 : 0xF0E442
            userName = "yellow"
            assistantCore = highContrast ? 0x4D94FF : 0x3380FF
        case .classicRed:
            userCore = 0xFF4D4D
            userName = "red"
            assistantCore = highContrast ? 0x4D94FF : 0x3380FF
        case .monochrome:
            userCore = 0xFFFFFF
            userName = "white"
            assistantCore = 0x8C8C8C
        }

        let scale = pointsToPixelsScale
        func layers(core: UInt32, coreWidth: Double, darkWidth: Double, whiteWidth: Double) -> InkStyle {
            InkStyle(layers: [
                InkStrokeLayer(rgb: whiteCasing, width: whiteWidth * scale),
                InkStrokeLayer(rgb: dark, width: darkWidth * scale),
                InkStrokeLayer(rgb: core, width: coreWidth * scale),
            ])
        }

        let userInk = layers(core: userCore, coreWidth: widths.userCore,
                             darkWidth: widths.userDark, whiteWidth: widths.userWhite)
        // The dot keeps the trail's casing margins around a 6 pt core.
        let userPenTip = layers(core: userCore, coreWidth: penTipDiameter,
                                darkWidth: penTipDiameter + (widths.userDark - widths.userCore),
                                whiteWidth: penTipDiameter + (widths.userWhite - widths.userCore))
        let assistantMark = layers(core: assistantCore, coreWidth: widths.assistantCore,
                                   darkWidth: widths.assistantDark, whiteWidth: widths.assistantWhite)

        let cursorOutline = InkCursorOutline(
            inner: InkStrokeLayer(rgb: dark, width: widths.cursorBand * scale),
            outer: InkStrokeLayer(rgb: whiteCasing, width: widths.cursorBand * scale))

        return ResolvedInkStyle(
            userInk: userInk,
            userPenTip: userPenTip,
            assistantMark: assistantMark,
            assistantDashed: differentiateWithoutColor || preset == .highVisibility,
            assistantDashPattern: [dashOn * scale, dashOff * scale],
            cursorOutline: cursorOutline,
            fade: InkFadeTimings(hold: holdSeconds,
                                 fade: reduceMotion ? reducedMotionFadeSeconds : fadeSeconds),
            userColourName: userName)
    }
}
