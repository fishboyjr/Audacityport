import AudioCore
import SwiftUI

/// Transport toolbar: skip, play, stop, record, loop, time display and meters.
struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.skipToStart() } label: { Image(systemName: "backward.end.fill") }
                .accessibilityLabel("Skip to start")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .disabled(model.isRecording || model.project.tracks.isEmpty)
            Button { model.stop() } label: { Image(systemName: "stop.fill") }
                .accessibilityLabel("Stop")
            Button { model.record() } label: {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2).foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: model.isRecording)
            }
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Record")
            Button { model.skipToEnd() } label: { Image(systemName: "forward.end.fill") }
                .accessibilityLabel("Skip to end")
            Toggle(isOn: $model.loopPlayback) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .accessibilityLabel("Loop selection")

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(model.formatTime(model.playhead)).font(.system(.callout, design: .monospaced))
                let r = model.project.selection.range
                Text(r.isEmpty ? " " : "\(model.formatTime(r.lowerBound)) – \(model.formatTime(r.upperBound))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            LevelMeter(left: model.levels.left, right: model.levels.right)
                .frame(width: 44, height: 30)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// Peak meter with clip indicator (dB scale, -60…0).
struct LevelMeter: View {
    var left: Float
    var right: Float

    var body: some View {
        Canvas { ctx, size in
            let h = (size.height - 2) / 2
            for (v, y) in [(left, CGFloat(0)), (right, h + 2)] {
                let db = DSP.dB(v)
                let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)), with: .color(.secondary.opacity(0.2)))
                let color: Color = db > -1 ? .red : db > -12 ? .yellow : .green
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width * frac, height: h)), with: .color(color))
            }
        }
        .accessibilityLabel("Level meter")
        .accessibilityValue(String(format: "Left %.0f dB, right %.0f dB", DSP.dB(left), DSP.dB(right)))
    }
}

/// Edit toolbar: undo/redo, clipboard, tools and zoom.
struct EditBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        let hasSel = !model.project.selection.isEmpty && !model.project.selection.trackIDs.isEmpty
        HStack(spacing: 16) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).accessibilityLabel("Redo")
            Divider().frame(height: 20)
            Button { model.cut() } label: { Image(systemName: "scissors") }
                .disabled(!hasSel).accessibilityLabel("Cut")
            Button { model.copy() } label: { Image(systemName: "doc.on.doc") }
                .disabled(!hasSel).accessibilityLabel("Copy")
            Button { model.paste() } label: { Image(systemName: "doc.on.clipboard") }
                .disabled(model.clipboard == nil).accessibilityLabel("Paste")
            Button { model.delete() } label: { Image(systemName: "delete.left") }
                .disabled(!hasSel).accessibilityLabel("Delete")
            Menu {
                Button("Silence Audio") { model.silence() }.disabled(!hasSel)
                Button("Trim Audio") { model.trim() }.disabled(!hasSel)
                Button("Split") { model.split() }
                Button("Join") { model.join() }.disabled(!hasSel)
                Button("Duplicate") { model.duplicate() }.disabled(!hasSel)
                Divider()
                Button("Select All") { model.selectAll() }
                Button("Select None") { model.selectNone() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More edit commands")
            Spacer()
            Picker("Tool", selection: $model.tool) {
                ForEach(EditTool.allCases) { t in Image(systemName: t.symbol).tag(t).accessibilityLabel(t.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
            Menu {
                Button("Zoom In") { model.zoom(by: 2, anchorX: model.x(forFrame: model.playhead)) }
                Button("Zoom Out") { model.zoom(by: 0.5, anchorX: model.x(forFrame: model.playhead)) }
                Button("Zoom to Selection") { model.zoomToSelection() }
                Button("Fit Project") { model.zoomToFit() }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
