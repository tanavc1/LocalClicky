//
//  AssistantMarksLayer.swift
//  LocalClicky
//
//  Draws the assistant's marks on one overlay window. It only strokes the
//  points MarkGeometry produced; there is no geometry decision here.
//
//  Painting order follows the contrast review: all white casings of every mark
//  first, then all dark casings, then all cores, so a core is never covered by
//  another mark's casing. Every mark is two sketchy passes of the same figure.
//  Round caps and joins, alpha 1.0 (the model's group opacity is the only fade),
//  no glow, blur or shadow. When Differentiate Without Colour (or the High
//  visibility preset) asks for it, only the cores are dashed 8 on, 5 off.
//
//  The draw-on is `progress`, animated by the model. The layer is decorative:
//  hidden from assistive technology (the assistant says what it marked out
//  loud) and from clicks.
//

import LocalBrainKit
import SwiftUI

/// A set of polylines, trimmed to the fraction `progress` of its total length
/// for the draw-on animation.
struct MarkShape: Shape {
    let subpaths: [MarkSubpath]
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for subpath in subpaths {
            guard let first = subpath.points.first else { continue }
            path.move(to: first)
            for point in subpath.points.dropFirst() { path.addLine(to: point) }
            if subpath.isClosed { path.closeSubpath() }
        }
        return progress >= 1 ? path : path.trimmedPath(from: 0, to: CGFloat(max(0, progress)))
    }
}

/// One overlay window's share of the marks: those drawn for its own display.
struct AssistantMarksLayer: View {
    @ObservedObject var marks: AssistantMarksModel
    let style: ResolvedInkStyle
    let screenFrame: CGRect

    var body: some View {
        let mine = marks.marks.filter { $0.displayFrame == screenFrame }
        if !mine.isEmpty {
            let layers = style.assistantMark.layers
            ZStack {
                ForEach(0..<layers.count, id: \.self) { layerIndex in
                    let layer = layers[layerIndex]
                    let isCore = layerIndex == layers.count - 1
                    ForEach(mine) { mark in
                        ForEach(0..<mark.geometry.passes.count, id: \.self) { pass in
                            MarkShape(subpaths: mark.geometry.passes[pass], progress: mark.progress)
                                .stroke(Color(layer), style: strokeStyle(for: layer, isCore: isCore))
                        }
                    }
                }
            }
            .compositingGroup()
            .opacity(marks.groupOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func strokeStyle(for layer: InkStrokeLayer, isCore: Bool) -> StrokeStyle {
        let dashed = isCore && style.assistantDashed
        return StrokeStyle(lineWidth: layer.width,
                           lineCap: .round,
                           lineJoin: .round,
                           dash: dashed ? style.assistantDashPattern.map { CGFloat($0) } : [])
    }
}
