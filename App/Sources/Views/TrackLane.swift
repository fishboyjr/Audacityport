import AudioCore
import SwiftUI

/// Snapshot of everything a lane needs to draw (read in `body` so Observation tracks it).
struct LaneGeometry {
    var viewStart: Double
    var framesPerPoint: Double
    func x(_ frame: Int) -> CGFloat { CGFloat((Double(frame) - viewStart) / framesPerPoint) }
    func frame(_ x: CGFloat) -> Int { Int((viewStart + Double(x) * framesPerPoint).rounded()) }
}

enum WaveformDrawing {
    /// Draw one clip channel into `rect` (rect spans the clip's full on-screen extent, possibly offscreen).
    static func draw(_ clip: Clip, channel: Int, in rect: CGRect, visibleWidth: CGFloat, geo: LaneGeometry,
                     cache: WaveformCache, color: Color, ctx: inout GraphicsContext) {
        let x0 = max(0, rect.minX), x1 = min(visibleWidth, rect.maxX)
        guard x1 > x0, clip.length > 0 else { return }
        let mid = rect.midY, half = rect.height / 2 * 0.95
        // Clip-local frames covered by the visible part.
        let f0 = max(0, Int(Double(x0 - rect.minX) * geo.framesPerPoint))
        let f1 = min(clip.length, Int(ceil(Double(x1 - rect.minX) * geo.framesPerPoint)))
        guard f1 > f0 else { return }

        // Centre line.
        ctx.fill(Path(CGRect(x: x0, y: mid, width: x1 - x0, height: 0.5)), with: .color(color.opacity(0.4)))

        if geo.framesPerPoint < 1 {
            // Zoomed in to individual samples: polyline (+ dots when very close).
            let s = clip.samples[min(channel, clip.channelCount - 1)]
            var path = Path()
            let lo = max(0, f0 - 1), hi = min(clip.length, f1 + 1)
            for i in lo..<hi {
                let p = CGPoint(x: rect.minX + CGFloat(Double(i) / geo.framesPerPoint), y: mid - CGFloat(s[i]) * half)
                if i == lo { path.move(to: p) } else { path.addLine(to: p) }
                if geo.framesPerPoint < 0.25 {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color))
                }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            return
        }

        let columns = max(1, Int((x1 - x0).rounded(.up)))
        let peaks = cache.peaks(clip: clip, channel: channel, range: f0..<f1, columns: columns)
        var path = Path()
        let colWidth = (x1 - x0) / CGFloat(columns)
        for c in 0..<columns {
            let top = mid - CGFloat(min(1, peaks.max[c])) * half
            let bottom = mid - CGFloat(max(-1, peaks.min[c])) * half
            path.addRect(CGRect(x: x0 + CGFloat(c) * colWidth, y: top, width: max(colWidth, 1), height: max(1, bottom - top)))
        }
        ctx.fill(path, with: .color(color))
    }
}

/// One track's waveform lane with selection, time-shift and scroll gestures.
struct TrackLane: View {
    @Bindable var model: EditorModel
    let track: Track

    @State private var anchor: Int?
    @State private var dragTracks: Set<UUID> = []
    @State private var movingClip: UUID?
    @State private var moveOffset: CGFloat = 0
    @State private var scrollBase: Double?

    var body: some View {
        let geo = LaneGeometry(viewStart: model.viewStart, framesPerPoint: model.framesPerPoint)
        let sel = model.project.selection
        let isSelected = sel.trackIDs.contains(track.id)
        let playheadX = geo.x(model.playhead)
        let color = TrackPalette.color(track.colorIndex)
        let cache = model.waveforms
        let moving = movingClip, offset = moveOffset
        let dimmed = track.isMuted
        let axValue: String = isSelected && !sel.isEmpty
            ? "Selected \(model.formatTime(sel.range.lowerBound)) to \(model.formatTime(sel.range.upperBound))"
            : "Not selected"

        Canvas { ctx, size in
            let chH = size.height / CGFloat(track.channelCount)
            for clip in track.clips {
                var x = geo.x(clip.start)
                if clip.id == moving { x += offset }
                let w = CGFloat(Double(clip.length) / geo.framesPerPoint)
                guard x + w >= 0, x <= size.width else { continue }
                let clipRect = CGRect(x: x, y: 0, width: w, height: size.height)
                ctx.fill(Path(roundedRect: clipRect.insetBy(dx: 0, dy: 1), cornerRadius: 3),
                         with: .color(color.opacity(clip.id == moving ? 0.3 : 0.14)))
                for ch in 0..<track.channelCount {
                    let r = CGRect(x: x, y: CGFloat(ch) * chH, width: w, height: chH)
                    WaveformDrawing.draw(clip, channel: ch, in: r, visibleWidth: size.width, geo: geo,
                                         cache: cache, color: dimmed ? .gray : color, ctx: &ctx)
                }
                // Clip boundary marks (split lines).
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color.opacity(0.6)))
            }
            if track.channelCount == 2 {
                ctx.fill(Path(CGRect(x: 0, y: chH, width: size.width, height: 0.5)), with: .color(.secondary.opacity(0.5)))
            }
            if isSelected {
                if sel.isEmpty {
                    let cx = geo.x(sel.cursor)
                    ctx.fill(Path(CGRect(x: cx, y: 0, width: 1, height: size.height)), with: .color(.primary))
                } else {
                    let a = geo.x(sel.range.lowerBound), b = geo.x(sel.range.upperBound)
                    ctx.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: size.height)),
                             with: .color(Color.accentColor.opacity(0.25)))
                }
            }
            ctx.fill(Path(CGRect(x: playheadX, y: 0, width: 1.5, height: size.height)), with: .color(.green))
        }
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .gesture(editGesture(geo), including: model.tool == .hand ? .subviews : .all)
        .simultaneousGesture(scrollGesture, including: model.tool == .hand ? .all : .subviews)
        .accessibilityElement()
        .accessibilityLabel("\(track.name) waveform")
        .accessibilityValue(axValue)
    }

    private func editGesture(_ geo: LaneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                switch model.tool {
                case .select: updateSelection(v, geo)
                case .timeShift: updateMove(v, geo)
                case .hand: break
                }
            }
            .onEnded { v in
                switch model.tool {
                case .select:
                    if abs(v.translation.width) < 3 {
                        let f = max(0, geo.frame(v.location.x))
                        model.setSelection(Selection(range: f..<f, trackIDs: [track.id]))
                        if !model.isPlaying { model.playhead = f }
                    }
                    anchor = nil
                case .timeShift:
                    if let id = movingClip {
                        model.moveClip(trackID: track.id, clipID: id, by: Int(Double(v.translation.width) * geo.framesPerPoint))
                    }
                    movingClip = nil
                    moveOffset = 0
                case .hand: break
                }
            }
    }

    private func updateSelection(_ v: DragGesture.Value, _ geo: LaneGeometry) {
        if anchor == nil {
            let sel = model.project.selection
            let start = max(0, geo.frame(v.startLocation.x))
            anchor = start
            // Grabbing an edge of the existing selection adjusts it, as on the desktop.
            if sel.trackIDs.contains(track.id) && !sel.isEmpty {
                if abs(v.startLocation.x - geo.x(sel.range.lowerBound)) < 16 { anchor = sel.range.upperBound }
                else if abs(v.startLocation.x - geo.x(sel.range.upperBound)) < 16 { anchor = sel.range.lowerBound }
            }
            dragTracks = sel.trackIDs.contains(track.id) && sel.trackIDs.count > 1 ? sel.trackIDs : [track.id]
        }
        guard let a = anchor, abs(v.translation.width) >= 3 else { return }
        model.setSelection(.between(a, max(0, geo.frame(v.location.x)), tracks: dragTracks))
    }

    private func updateMove(_ v: DragGesture.Value, _ geo: LaneGeometry) {
        if movingClip == nil {
            let f = geo.frame(v.startLocation.x)
            movingClip = track.clips.first { f >= $0.start && f < $0.end }?.id
        }
        moveOffset = v.translation.width
    }

    private var scrollGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                let base = scrollBase ?? model.viewStart
                if scrollBase == nil { scrollBase = base }
                model.viewStart = max(0, base - Double(v.translation.width) * model.framesPerPoint)
            }
            .onEnded { _ in scrollBase = nil }
    }
}

/// Live waveform of the take being recorded (drawn from the engine's block summary).
struct RecordingLane: View {
    @Bindable var model: EditorModel
    let preview: EditorModel.RecordingPreview

    var body: some View {
        let geo = LaneGeometry(viewStart: model.viewStart, framesPerPoint: model.framesPerPoint)
        let snap = preview.snapshot
        // Project frames per preview block.
        let blockFrames = Double(AudioEngine.previewBlock) * model.project.sampleRate / snap.inputRate
        let start = preview.start
        Canvas { ctx, size in
            guard !snap.max.isEmpty else { return }
            let x0 = max(0, geo.x(start))
            let x1 = min(size.width, geo.x(start + Int(Double(snap.max.count) * blockFrames)))
            guard x1 > x0 else { return }
            let mid = size.height / 2
            var path = Path()
            for c in 0..<Int(x1 - x0) {
                let fa = Double(geo.frame(x0 + CGFloat(c)) - start) / blockFrames
                let fb = Double(geo.frame(x0 + CGFloat(c + 1)) - start) / blockFrames
                let lo = max(0, min(snap.max.count - 1, Int(fa)))
                let hi = max(lo + 1, min(snap.max.count, Int(fb.rounded(.up))))
                var mn: Float = 0, mx: Float = 0
                for i in lo..<hi { mn = min(mn, snap.min[i]); mx = max(mx, snap.max[i]) }
                path.addRect(CGRect(x: x0 + CGFloat(c), y: mid - CGFloat(mx) * mid, width: 1,
                                    height: max(1, CGFloat(mx - mn) * mid)))
            }
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(.red.opacity(0.08)))
            ctx.fill(path, with: .color(.red))
        }
        .background(Color(uiColor: .systemBackground))
    }
}
