//
//  AssistantMarksModel.swift
//  LocalClicky
//
//  The marks the assistant has drawn this turn (ink out): circles, arrows,
//  lines, curves, polygons and highlight boxes. The response pipeline adds a
//  mark the moment its tag closes in the stream; each overlay window draws the
//  marks that belong to its own display (AssistantMarksLayer).
//
//  Lifecycle:
//    - add: the mark starts at progress 0 and draws on over 0.35 s. With Reduce
//      Motion it appears at once and the group fades in over 0.15 s instead
//      (only for the first mark of a group, since the group is the unit that
//      fades), with no draw-on;
//    - speech ends: after the palette's hold (1.5 s) the whole group fades over
//      the palette's fade time, then clears;
//    - the next key press clears everything at once.
//  Fades animate the whole group's opacity, never a single stroke.
//

import AppKit
import Combine
import LocalBrainKit
import SwiftUI

@MainActor
final class AssistantMarksModel: ObservableObject {
    struct Mark: Identifiable {
        let id = UUID()
        /// The display the mark was drawn for, in global AppKit points. An
        /// overlay shows the mark only when this is its own screen's frame.
        let displayFrame: CGRect
        let geometry: MarkGeometry
        /// 0...1, how much of the stroke is drawn so far.
        var progress: Double
    }

    static let drawOnSeconds: Double = 0.35
    static let reducedMotionFadeInSeconds: Double = 0.15

    @Published private(set) var marks: [Mark] = []
    /// The whole group's opacity. 1 except during a group fade.
    @Published private(set) var groupOpacity: Double = 1

    var isShowing: Bool { !marks.isEmpty }

    private var clearTask: Task<Void, Never>?

    /// Adds a mark. `reduceMotion` is read by the caller from the system option.
    func add(geometry: MarkGeometry, displayFrame: CGRect, reduceMotion: Bool) {
        // A new mark during a pending or running fade keeps the group on screen.
        clearTask?.cancel()
        clearTask = nil
        let startsGroup = marks.isEmpty
        if groupOpacity < 1 { groupOpacity = 1 }

        let mark = Mark(displayFrame: displayFrame, geometry: geometry, progress: reduceMotion ? 1 : 0)
        marks.append(mark)

        if reduceMotion {
            if startsGroup {
                groupOpacity = 0
                DispatchQueue.main.async { [weak self] in
                    withAnimation(.linear(duration: Self.reducedMotionFadeInSeconds)) { self?.groupOpacity = 1 }
                }
            }
        } else {
            // One runloop turn later, so the view first renders progress 0 and
            // the change to 1 animates.
            let id = mark.id
            DispatchQueue.main.async { [weak self] in
                withAnimation(.linear(duration: Self.drawOnSeconds)) { self?.setProgress(1, for: id) }
            }
        }
    }

    private func setProgress(_ value: Double, for id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        marks[index].progress = value
    }

    /// Speech has ended: hold, fade the group, clear. A later `add` or
    /// `clearNow` cancels it.
    func scheduleClear(hold: Double, fade: Double) {
        guard isShowing else { return }
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.linear(duration: fade)) { self.groupOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(fade * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.marks = []
            self.groupOpacity = 1
        }
    }

    /// Clears at once (the next key press, or a new turn).
    func clearNow() {
        clearTask?.cancel()
        clearTask = nil
        guard isShowing || groupOpacity != 1 else { return }
        marks = []
        groupOpacity = 1
    }
}
