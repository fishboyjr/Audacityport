import AudioCore
import SwiftUI

enum TrackPalette {
    static let colors: [Color] = [.blue, .teal, .indigo, .green, .orange, .pink, .purple, .mint]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

/// Ruler + track lanes. Horizontal position is a custom viewport (viewStart / framesPerPoint)
/// so drawing cost depends only on screen width, never on project length.
struct TracksTimeline: View {
    @Bindable var model: EditorModel
    @State private var pinchBase: Double?

    static let headerWidth: CGFloat = 112

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(model.formatTime(model.playhead))
                        .font(.caption2.monospacedDigit())
                        .frame(width: Self.headerWidth)
                    RulerView(model: model)
                }
                .frame(height: 40)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(model.project.tracks) { track in
                            HStack(spacing: 0) {
                                TrackHeaderView(model: model, track: track)
                                    .frame(width: Self.headerWidth)
                                TrackLane(model: model, track: track)
                            }
                            .frame(height: track.channelCount == 2 ? 150 : 104)
                        }
                        if let rec = model.recordingPreview {
                            HStack(spacing: 0) {
                                Label("Recording", systemImage: "record.circle.fill")
                                    .font(.caption).foregroundStyle(.red)
                                    .frame(width: Self.headerWidth)
                                RecordingLane(model: model, preview: rec)
                            }
                            .frame(height: 104)
                        }
                    }
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? model.framesPerPoint
                        if pinchBase == nil { pinchBase = base }
                        let anchor = value.startLocation.x - Self.headerWidth
                        let target = base / value.magnification
                        model.zoom(by: model.framesPerPoint / target, anchorX: max(0, anchor))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .onAppear { model.viewWidth = max(100, geo.size.width - Self.headerWidth) }
            .onChange(of: geo.size.width) { _, w in model.viewWidth = max(100, w - Self.headerWidth) }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// Time ruler: tap to move the playhead, drag to scroll.
struct RulerView: View {
    @Bindable var model: EditorModel
    @State private var dragBase: Double?

    var body: some View {
        let viewStart = model.viewStart, fpp = model.framesPerPoint, rate = model.project.sampleRate
        let playheadX = model.x(forFrame: model.playhead)
        let labels = model.project.labels
        let sel = model.project.selection.range
        Canvas { ctx, size in
            // Pick a tick spacing that leaves ~80 pt between labels.
            let secondsPerPoint = fpp / rate
            let candidates: [Double] = [0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
            let major = candidates.first { $0 / secondsPerPoint >= 80 } ?? 3600
            let minor = major / 5
            let t0 = viewStart / rate
            let t1 = t0 + Double(size.width) * secondsPerPoint
            var t = (t0 / minor).rounded(.down) * minor
            while t <= t1 {
                let x = (t * rate - viewStart) / fpp
                let isMajor = abs((t / major).rounded() - t / major) < 1e-6
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 14 : 6)))
                ctx.stroke(p, with: .color(.secondary), lineWidth: 1)
                if isMajor {
                    let label = major < 1 ? String(format: "%.3f", t) : Self.clock(t)
                    ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 10), anchor: .leading)
                }
                t += minor
            }
            // Selection band.
            if !sel.isEmpty {
                let a = (Double(sel.lowerBound) - viewStart) / fpp, b = (Double(sel.upperBound) - viewStart) / fpp
                ctx.fill(Path(CGRect(x: a, y: size.height - 4, width: max(1, b - a), height: 4)), with: .color(.accentColor))
            }
            // Labels.
            for l in labels {
                let x = (Double(l.range.lowerBound) - viewStart) / fpp
                guard x > -200, x < Double(size.width) else { continue }
                ctx.fill(Path(CGRect(x: x, y: 18, width: 2, height: 22)), with: .color(.orange))
                ctx.draw(Text(l.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange),
                         at: CGPoint(x: x + 4, y: 26), anchor: .leading)
            }
            // Playhead.
            var ph = Path()
            ph.move(to: CGPoint(x: playheadX - 5, y: 0))
            ph.addLine(to: CGPoint(x: playheadX + 5, y: 0))
            ph.addLine(to: CGPoint(x: playheadX, y: 8))
            ph.closeSubpath()
            ctx.fill(ph, with: .color(.green))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if abs(v.translation.width) < 4 && dragBase == nil { return }
                    let base = dragBase ?? model.viewStart
                    if dragBase == nil { dragBase = base }
                    model.viewStart = max(0, base - Double(v.translation.width) * model.framesPerPoint)
                }
                .onEnded { v in
                    if dragBase == nil { model.seek(to: model.frame(atX: v.location.x)) }
                    dragBase = nil
                }
        )
        .accessibilityLabel("Timeline ruler")
        .accessibilityHint("Tap to move the playhead, drag to scroll")
    }

    static func clock(_ t: Double) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s) : String(format: "%d:%02d", m, s)
    }
}
