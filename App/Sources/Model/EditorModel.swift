import AudioCore
import Foundation
import Observation
import SwiftUI

/// Editing tools, mirroring the desktop Tools toolbar.
enum EditTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case timeShift = "Move Clips"
    case hand = "Scroll"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "character.cursor.ibeam"
        case .timeShift: return "arrow.left.and.right"
        case .hand: return "hand.draw"
        }
    }
}

@MainActor
@Observable
final class EditorModel {
    // Document
    var project: Project
    private(set) var history: History
    var projectURL: URL?
    var isDirty = false

    // Editing state
    var clipboard: Clipboard?
    var noiseProfile: [Float]?
    var tool: EditTool = .select
    var errorMessage: String?
    var statusMessage: String?
    var isBusy = false

    // Viewport: first visible frame and zoom (frames per point).
    var viewStart: Double = 0
    var framesPerPoint: Double = 441
    var viewWidth: Double = 300

    // Transport
    var playhead: Int = 0
    var isPlaying = false
    var isRecording = false
    var loopPlayback = false
    var levels = AudioEngine.Levels()
    var recordingPreview: RecordingPreview?

    struct RecordingPreview {
        var start: Int
        var snapshot: AudioEngine.RecordingSnapshot
    }

    let engine = AudioEngine()
    let waveforms = WaveformCache()
    @ObservationIgnored private var displayTimer: Timer?

    init(project: Project = Project()) {
        self.project = project
        self.history = History(initial: project)
        engine.onPlaybackFinished = { [weak self] in
            MainActor.assumeIsolated { self?.playbackFinished() }
        }
    }

    // MARK: - Undoable edits

    /// Run an edit as one undo step. Errors are shown to the user and leave the project unchanged.
    func perform(_ name: String, _ body: (inout Project) throws -> Void) {
        var p = project
        do {
            try body(&p)
            project = p
            history.push(p, name)
            isDirty = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run a potentially slow edit (effects) off the main thread.
    func performAsync(_ name: String, _ body: @escaping @Sendable (inout Project) throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Applying \(name)…"
        let snapshot = project
        Task.detached(priority: .userInitiated) {
            var p = snapshot
            let result: Result<Project, Error>
            do { try body(&p); result = .success(p) } catch { result = .failure(error) }
            await MainActor.run {
                self.isBusy = false
                self.statusMessage = nil
                switch result {
                case .success(let p):
                    self.project = p
                    self.history.push(p, name)
                    self.isDirty = true
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    /// Start a fresh undo history at the current project (new/open).
    func resetHistory() {
        history = History(initial: project)
        waveforms.removeAll()
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        stop()
        if let p = history.undo() { project = p; isDirty = true }
    }

    func redo() {
        stop()
        if let p = history.redo() { project = p; isDirty = true }
    }

    /// Selection changes are not undo steps but are remembered in the current state.
    func setSelection(_ sel: Selection) {
        project.selection = sel
        history.amend(project)
    }

    // MARK: - Edit menu

    func cut() { perform("Cut") { p in clipboard = try p.cut() } }
    func copy() {
        do { clipboard = try project.copy(); statusMessage = "Copied" } catch { errorMessage = error.localizedDescription }
    }
    func paste() {
        guard let clip = clipboard else { errorMessage = EditError.emptyClipboard.localizedDescription; return }
        perform("Paste") { try $0.paste(clip) }
    }
    func delete() { perform("Delete") { try $0.delete() } }
    func silence() { perform("Silence") { try $0.silenceSelection() } }
    func trim() { perform("Trim Audio") { try $0.trim() } }
    func split() { perform("Split") { try $0.split() } }
    func join() { perform("Join") { try $0.join() } }
    func duplicate() { perform("Duplicate") { try $0.duplicate() } }

    func selectAll() {
        setSelection(Selection(range: 0..<max(project.endFrame, 0), trackIDs: Set(project.tracks.map(\.id))))
    }

    func selectNone() {
        setSelection(Selection(range: project.selection.cursor..<project.selection.cursor, trackIDs: []))
    }

    // MARK: - Tracks

    func addTrack(stereo: Bool) {
        perform("New Track") { p in
            let id = p.addTrack(channels: stereo ? 2 : 1)
            p.selection.trackIDs = [id]
        }
    }

    func removeSelectedTracks() {
        let ids = project.selection.trackIDs
        guard !ids.isEmpty else { return }
        perform("Remove Tracks") { $0.removeTracks(ids) }
    }

    func removeTrack(_ id: UUID) { perform("Remove Track") { $0.removeTracks([id]) } }

    func updateTrack(_ id: UUID, _ name: String, _ change: (inout Track) -> Void) {
        guard let i = project.trackIndex(id) else { return }
        perform(name) { change(&$0.tracks[i]) }
    }

    func mixAndRender() { performAsync("Mix and Render") { $0.mixAndRender() } }

    func addLabel(_ text: String) { perform("Add Label") { $0.addLabel(text) } }

    func moveClip(trackID: UUID, clipID: UUID, by delta: Int) {
        guard delta != 0, let i = project.trackIndex(trackID) else { return }
        perform("Move Clip") { $0.tracks[i].moveClip(clipID, by: delta) }
    }

    // MARK: - Effects

    func apply(_ effect: any AudioEffect, values: EffectValues) {
        stop()
        let ctx = EffectContext(sampleRate: project.sampleRate, noiseProfile: noiseProfile)
        performAsync(effect.name) { try $0.apply(effect, values: values, context: ctx) }
    }

    /// Preview: process the first few seconds of the selection and play it.
    func preview(_ effect: any AudioEffect, values: EffectValues) {
        stop()
        var p = project
        let sel = p.selection
        let previewRange = sel.range.lowerBound..<min(sel.range.upperBound, sel.range.lowerBound + p.frames(6))
        p.selection.range = effect is any AudioGenerator ? sel.cursor..<sel.cursor : previewRange
        let ctx = EffectContext(sampleRate: p.sampleRate, noiseProfile: noiseProfile)
        do {
            try p.apply(effect, values: values, context: ctx)
            let end = p.selection.range.upperBound
            // Only audition the affected tracks.
            p.tracks = p.tracks.filter { p.selection.trackIDs.contains($0.id) }
            try engine.play(p, from: p.selection.range.lowerBound, to: end)
            startDisplayTimer()
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func captureNoiseProfile() {
        do {
            let clip = try project.copy()
            guard let first = clip.tracks.first, first.frameCount >= NoiseReduction.fftSize else {
                errorMessage = "Select at least 0.05 s of noise."
                return
            }
            noiseProfile = NoiseReduction.profile(from: first)
            statusMessage = "Noise profile captured"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard !isRecording else { return }
        let sel = project.selection
        let start = sel.isEmpty ? playhead : sel.range.lowerBound
        let end: Int? = sel.isEmpty ? nil : sel.range.upperBound
        guard start < (end ?? project.endFrame) else { return }
        do {
            try engine.play(project, from: start, to: end)
            isPlaying = true
            startDisplayTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        engine.stop()
        isPlaying = false
        levels = .init()
        stopDisplayTimer()
    }

    func seek(to frame: Int) {
        let wasPlaying = isPlaying
        stop()
        playhead = max(0, frame)
        if project.selection.isEmpty { setSelection(Selection(range: playhead..<playhead, trackIDs: project.selection.trackIDs)) }
        if wasPlaying { play() }
    }

    func skipToStart() { seek(to: 0); viewStart = 0 }
    func skipToEnd() { seek(to: project.endFrame) }

    private func playbackFinished() {
        guard isPlaying else { return }
        if loopPlayback && !project.selection.isEmpty {
            play()
        } else {
            isPlaying = false
            levels = .init()
            stopDisplayTimer()
        }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        levels = engine.levels
        if isRecording, let start = recordingPreview?.start {
            let snap = engine.recordingSnapshot()
            recordingPreview = RecordingPreview(start: start, snapshot: snap)
            playhead = start + Int(Double(snap.frames) * project.sampleRate / snap.inputRate)
            follow(playhead)
        } else if let f = engine.currentFrame {
            playhead = f
            follow(f)
        }
    }

    /// Page the view when the playhead leaves it (like the desktop "pinned" off mode).
    private func follow(_ frame: Int) {
        let visible = viewWidth * framesPerPoint
        if Double(frame) > viewStart + visible * 0.95 || Double(frame) < viewStart {
            viewStart = max(0, Double(frame) - visible * 0.05)
        }
    }

    // MARK: - Recording

    func record() {
        guard !isRecording else { stopRecording(); return }
        Task {
            guard await AudioEngine.requestRecordPermission() else {
                errorMessage = "Microphone access is off. Enable it in Settings › Privacy › Microphone."
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        engine.stop()
        isPlaying = false
        let start = project.selection.isEmpty ? playhead : project.selection.range.lowerBound
        do {
            // Overdub: play existing tracks while recording.
            if project.endFrame > start { try engine.play(project, from: start, to: nil) }
            let rate = try engine.startRecording(channels: 2)
            recordingPreview = RecordingPreview(start: start,
                                                snapshot: .init(min: [], max: [], frames: 0, inputRate: rate))
            isRecording = true
            startDisplayTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        let (audio, rate) = engine.stopRecording()
        engine.stop()
        isRecording = false
        stopDisplayTimer()
        let start = recordingPreview?.start ?? playhead
        recordingPreview = nil
        guard audio.frameCount > 0 else { return }
        perform("Record") { p in
            let n = p.tracks.count + 1
            let id = p.importAudio(audio, sampleRate: rate, name: "Recording \(n)", at: start)
            let len = p.tracks.last?.endFrame ?? start
            p.selection = Selection(range: start..<len, trackIDs: [id])
        }
        playhead = project.selection.range.upperBound
    }

    // MARK: - Viewport helpers

    func frame(atX x: Double) -> Int { max(0, Int(viewStart + x * framesPerPoint)) }
    func x(forFrame f: Int) -> Double { (Double(f) - viewStart) / framesPerPoint }

    func zoom(by factor: Double, anchorX: Double) {
        let anchor = viewStart + anchorX * framesPerPoint
        framesPerPoint = min(max(framesPerPoint / factor, 1.0 / 16), project.sampleRate * 60)
        viewStart = max(0, anchor - anchorX * framesPerPoint)
    }

    func zoomToFit() {
        let end = max(project.endFrame, project.frames(10))
        framesPerPoint = Double(end) / max(100, viewWidth - 20)
        viewStart = 0
    }

    func zoomToSelection() {
        let r = project.selection.range
        guard !r.isEmpty else { return }
        framesPerPoint = Double(r.count) / max(100, viewWidth - 40)
        viewStart = max(0, Double(r.lowerBound) - 20 * framesPerPoint)
    }

    func formatTime(_ frames: Int) -> String {
        let t = project.seconds(frames)
        let h = Int(t) / 3600, m = (Int(t) / 60) % 60, s = t.truncatingRemainder(dividingBy: 60)
        return h > 0 ? String(format: "%d:%02d:%06.3f", h, m, s) : String(format: "%02d:%06.3f", m, s)
    }
}
