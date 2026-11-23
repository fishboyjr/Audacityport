import AudioCore
import SwiftUI

/// Track control panel: name, mute/solo, gain and pan (like the desktop track control panel).
struct TrackHeaderView: View {
    @Bindable var model: EditorModel
    let track: Track

    @State private var gain: Float = 0
    @State private var pan: Float = 0
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let selected = model.project.selection.trackIDs.contains(track.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(TrackPalette.color(track.colorIndex)).frame(width: 8, height: 8)
                Menu {
                    Button("Rename…") { newName = track.name; renaming = true }
                    Button(track.channelCount == 1 ? "Make Stereo" : "Make Mono") { toggleChannels() }
                    Button("Select Track") { selectTrack(add: false) }
                    Button("Add to Selection") { selectTrack(add: true) }
                    Divider()
                    Button("Delete Track", role: .destructive) { model.removeTrack(track.id) }
                } label: {
                    Text(track.name).font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                toggle("M", on: track.isMuted, tint: .orange) {
                    model.updateTrack(track.id, track.isMuted ? "Unmute" : "Mute") { $0.isMuted.toggle() }
                }
                toggle("S", on: track.isSolo, tint: .yellow) {
                    model.updateTrack(track.id, track.isSolo ? "Unsolo" : "Solo") { $0.isSolo.toggle() }
                }
                Text(track.channelCount == 2 ? "ST" : "MO").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            miniSlider(value: $gain, range: -36...12, label: String(format: "%+.0f dB", gain)) {
                model.updateTrack(track.id, "Gain") { $0.gainDB = gain }
            }
            miniSlider(value: $pan, range: -1...1, label: panLabel) {
                model.updateTrack(track.id, "Pan") { $0.pan = pan }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemBackground))
        .contentShape(Rectangle())
        .onTapGesture { selectTrack(add: false) }
        .onAppear { gain = track.gainDB; pan = track.pan }
        .onChange(of: track.gainDB) { _, v in gain = v }
        .onChange(of: track.pan) { _, v in pan = v }
        .alert("Rename Track", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.updateTrack(track.id, "Rename Track") { $0.name = newName } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var panLabel: String {
        abs(pan) < 0.01 ? "Center" : String(format: "%.0f%% %@", abs(pan) * 100, pan < 0 ? "L" : "R")
    }

    private func toggle(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2.bold())
                .frame(width: 24, height: 20)
                .background(on ? tint : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(on ? .black : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "M" ? "Mute" : "Solo")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func miniSlider(value: Binding<Float>, range: ClosedRange<Float>, label: String,
                            commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Slider(value: value, in: range, onEditingChanged: { editing in if !editing { commit() } })
                .controlSize(.mini)
            Text(label).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func selectTrack(add: Bool) {
        var sel = model.project.selection
        if add { sel.trackIDs.insert(track.id) } else { sel.trackIDs = [track.id] }
        model.setSelection(sel)
    }

    private func toggleChannels() {
        model.updateTrack(track.id, track.channelCount == 1 ? "Make Stereo" : "Make Mono") { t in
            let ch = t.channelCount == 1 ? 2 : 1
            t.channelCount = ch
            for i in t.clips.indices { t.clips[i].samples = conform(t.clips[i].samples, channels: ch) }
        }
    }
}
