//
//  InkTrailModel.swift
//  LocalClicky
//
//  The live ink trail. While the push-to-talk keys are held, the overlay's
//  existing 16 ms mouse poll feeds this model one sample per tick: a global
//  AppKit point and a monotonic time. There is no event tap and no mouse
//  monitor here, so ink needs no extra permission.
//
//  The model owns the stroke's lifecycle:
//    - the key-down edge (seen by the poll) clears the last trail and starts a
//      new stroke;
//    - nothing is drawn until the pointer is 8 pt from where the stroke began;
//    - a sample closer than 1.5 pt to the last kept one is dropped (the
//      closing sample at release is always kept);
//    - while the keys are held the ink stays;
//    - after release it holds for 1.5 s, then fades the whole group's opacity
//      (never a single stroke), then clears;
//    - the next press clears it at once.
//
//  Each overlay window draws only the samples that fall on its own screen
//  (InkTrailLayer). The look comes from InkPalette, re-resolved live when the
//  system's accessibility display options change.
//

import AppKit
import Combine
import LocalBrainKit
import SwiftUI

/// The system display options that change how ink looks.
enum InkDisplayOptions {
    static func current() -> (increaseContrast: Bool, differentiateWithoutColor: Bool, reduceMotion: Bool) {
        let workspace = NSWorkspace.shared
        return (workspace.accessibilityDisplayShouldIncreaseContrast,
                workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
                workspace.accessibilityDisplayShouldReduceMotion)
    }
}

@MainActor
final class InkTrailModel: ObservableObject {
    /// A hard cap so a very long hold cannot grow without bound (about 65 s at 60 Hz).
    private static let maximumSamples = 4000
    private static let presetDefaultsKey = "inkPreset"

    /// Samples in global AppKit points, oldest first. Kept after release so the
    /// ink can fade, and read by the turn at key up.
    @Published private(set) var samples: [InkSample] = []
    /// True once the pointer has moved far enough from the press for ink to show.
    @Published private(set) var isDrawing = false
    /// The whole group's opacity. Animated by the fade; never per stroke.
    @Published private(set) var groupOpacity: Double = 1
    /// Resolved in points (scale 1) for the overlay.
    @Published private(set) var style: ResolvedInkStyle

    private(set) var isHeld = false
    private var origin: CGPoint?
    private var fadeTask: Task<Void, Never>?

    /// The user's chosen preset, set from the panel's "Ink style" menu. It reads
    /// and writes UserDefaults and re-resolves the style live.
    var preset: InkPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Self.presetDefaultsKey)
            refreshStyle()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.presetDefaultsKey).flatMap(InkPreset.init(rawValue:))
        let initialPreset = stored ?? .standard
        preset = initialPreset
        style = Self.resolve(preset: initialPreset, pointsToPixelsScale: 1)
        // The model lives as long as the app, so the observer is never removed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStyle() }
        }
    }

    // MARK: - Style

    static func resolve(preset: InkPreset, pointsToPixelsScale: Double) -> ResolvedInkStyle {
        let options = InkDisplayOptions.current()
        return InkPalette.resolve(preset: preset,
                                  increaseContrast: options.increaseContrast,
                                  differentiateWithoutColor: options.differentiateWithoutColor,
                                  reduceMotion: options.reduceMotion,
                                  pointsToPixelsScale: pointsToPixelsScale)
    }

    /// The same look at another scale, for compositing onto a screenshot.
    func resolvedStyle(pointsToPixelsScale: Double) -> ResolvedInkStyle {
        Self.resolve(preset: preset, pointsToPixelsScale: pointsToPixelsScale)
    }

    func refreshStyle() {
        style = Self.resolve(preset: preset, pointsToPixelsScale: 1)
    }

    // MARK: - Feeding

    /// Called from every overlay's 16 ms poll. Edges (press, release) may come
    /// from any overlay; only the overlay whose screen holds the pointer
    /// (`sampleHere`) adds a sample, so a tick is never recorded twice.
    func tick(isShortcutPressed: Bool, mouse: CGPoint, sampleHere: Bool) {
        if isShortcutPressed {
            if !isHeld { beginStroke() }
            guard sampleHere else { return }
            append(InkSample(point: mouse, time: ProcessInfo.processInfo.systemUptime))
        } else if isHeld {
            endStroke(finalPoint: mouse)
        }
    }

    /// Ends the stroke (idempotent) and returns its samples. The final sample
    /// is the pointer's position at release, so a pause at the end of the
    /// stroke still counts as a dwell. Starts the hold and fade.
    @discardableResult
    func endStroke(finalPoint: CGPoint) -> [InkSample] {
        guard isHeld else { return samples }
        isHeld = false
        append(InkSample(point: finalPoint, time: ProcessInfo.processInfo.systemUptime), isFinal: true)
        scheduleFade()
        return samples
    }

    private func beginStroke() {
        fadeTask?.cancel()
        fadeTask = nil
        isHeld = true
        origin = nil
        samples = []
        isDrawing = false
        groupOpacity = 1
    }

    private func append(_ sample: InkSample, isFinal: Bool = false) {
        guard samples.count < Self.maximumSamples else { return }
        guard InkStroke.shouldKeepSample(sample.point, after: samples.last?.point, isFinal: isFinal) else { return }
        if origin == nil { origin = sample.point }
        samples.append(sample)
        if !isDrawing, let origin,
           InkGeometry.distance(sample.point, origin) >= InkStroke.liveTrailThreshold {
            isDrawing = true
        }
    }

    // MARK: - Fade

    private func scheduleFade() {
        fadeTask?.cancel()
        guard isDrawing else {
            samples = []
            return
        }
        let timings = style.fade
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timings.hold * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.linear(duration: timings.fade)) { self.groupOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(timings.fade * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.samples = []
            self.isDrawing = false
            self.groupOpacity = 1
        }
    }
}

// MARK: - Drawing

extension Color {
    init(_ layer: InkStrokeLayer) {
        self.init(.sRGB, red: layer.red, green: layer.green, blue: layer.blue, opacity: layer.alpha)
    }
}

/// A smooth path through runs of points: quadratic curves through the midpoints,
/// so a 16 ms trail of straight hops reads as one fluid line. A run is a stretch
/// of consecutive samples on one screen.
struct InkTrailPath: Shape {
    let runs: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in runs where !run.isEmpty {
            path.move(to: run[0])
            if run.count == 1 {
                path.addLine(to: run[0])
                continue
            }
            for index in 1..<(run.count - 1) {
                let middle = CGPoint(x: (run[index].x + run[index + 1].x) / 2,
                                     y: (run[index].y + run[index + 1].y) / 2)
                path.addQuadCurve(to: middle, control: run[index])
            }
            path.addLine(to: run[run.count - 1])
        }
        return path
    }
}

/// One overlay window's share of the ink: the samples on its own screen, as
/// three stacked strokes (white casing, dark casing, core) and a pen-tip dot at
/// the head. Decorative, so hidden from assistive technology and from clicks.
struct InkTrailLayer: View {
    @ObservedObject var trail: InkTrailModel
    let screenFrame: CGRect

    var body: some View {
        if trail.isDrawing {
            let runs = localRuns()
            let head = trail.samples.last.flatMap { screenFrame.contains($0.point) ? localPoint($0.point) : nil }
            ZStack {
                if !runs.isEmpty {
                    ForEach(0..<trail.style.userInk.layers.count, id: \.self) { index in
                        let layer = trail.style.userInk.layers[index]
                        InkTrailPath(runs: runs)
                            .stroke(Color(layer),
                                    style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                        if let head {
                            let tip = trail.style.userPenTip.layers[index]
                            Circle()
                                .fill(Color(tip))
                                .frame(width: tip.width, height: tip.width)
                                .position(head)
                        }
                    }
                }
            }
            .opacity(trail.groupOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.origin.x,
                y: (screenFrame.origin.y + screenFrame.height) - point.y)
    }

    /// Consecutive samples on this screen, converted to overlay-local points.
    private func localRuns() -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for sample in trail.samples {
            if screenFrame.contains(sample.point) {
                current.append(localPoint(sample.point))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
