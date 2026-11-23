import Foundation

/// Audio copied from the selection: one entry per selected track, in track order.
public struct Clipboard: Equatable, Sendable {
    public var tracks: [PlanarAudio]
    public var sampleRate: Double

    public init(tracks: [PlanarAudio], sampleRate: Double) {
        self.tracks = tracks
        self.sampleRate = sampleRate
    }

    public var length: Int { tracks.map(\.frameCount).max() ?? 0 }
    public var isEmpty: Bool { length == 0 }
}

public enum EditError: Error, Equatable, LocalizedError {
    case noSelection
    case noTracksSelected
    case emptyClipboard
    case effectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSelection: return "Select some audio first."
        case .noTracksSelected: return "Select at least one track."
        case .emptyClipboard: return "Nothing to paste."
        case .effectFailed(let why): return why
        }
    }
}

/// The Edit menu, implemented as value-type transformations of `Project`.
public extension Project {
    private func requireRange() throws -> (Range<Int>, [Int]) {
        let idx = selectedTrackIndices
        guard !idx.isEmpty else { throw EditError.noTracksSelected }
        guard !selection.isEmpty else { throw EditError.noSelection }
        return (selection.range, idx)
    }

    func copy() throws -> Clipboard {
        let (range, idx) = try requireRange()
        return Clipboard(tracks: idx.map { tracks[$0].render(range) }, sampleRate: sampleRate)
    }

    mutating func cut() throws -> Clipboard {
        let clip = try copy()
        try delete()
        return clip
    }

    /// Delete the selection and close the gap (ripple delete).
    mutating func delete() throws {
        let (range, idx) = try requireRange()
        for i in idx { tracks[i].remove(range, shift: true) }
        shiftLabels(after: range.upperBound, by: -range.count, removing: range)
        selection.range = range.lowerBound..<range.lowerBound
    }

    /// Paste replaces the selection (or inserts at the cursor).
    /// With no selected tracks, the clipboard is pasted into new tracks.
    mutating func paste(_ clipboard: Clipboard) throws {
        guard !clipboard.isEmpty else { throw EditError.emptyClipboard }
        let data = clipboard.tracks.map { resampled($0, from: clipboard.sampleRate) }
        let at = selection.cursor
        var idx = selectedTrackIndices
        if idx.isEmpty {
            for (n, audio) in data.enumerated() {
                tracks.append(Track(name: "Pasted \(n + 1)", channelCount: audio.count,
                                    colorIndex: tracks.count))
            }
            idx = Array((tracks.count - data.count)..<tracks.count)
            selection.trackIDs = Set(idx.map { tracks[$0].id })
        }
        if !selection.isEmpty {
            for i in idx { tracks[i].remove(selection.range, shift: true) }
        }
        let length = data.map(\.frameCount).max() ?? 0
        for (k, i) in idx.enumerated() {
            tracks[i].insert(data[min(k, data.count - 1)], at: at)
        }
        selection.range = at..<(at + length)
    }

    /// Replace the selection with silence (keeps duration).
    mutating func silenceSelection() throws {
        let (range, idx) = try requireRange()
        for i in idx {
            if tracks[i].clips.contains(where: { $0.intersects(range) }) {
                tracks[i].silence(range)
            }
        }
    }

    /// Keep only the selected audio in selected tracks.
    mutating func trim() throws {
        let (range, idx) = try requireRange()
        for i in idx { tracks[i].trim(to: range) }
    }

    /// Split clips at the selection boundaries.
    mutating func split() throws {
        let idx = selectedTrackIndices
        guard !idx.isEmpty else { throw EditError.noTracksSelected }
        for i in idx {
            tracks[i].split(at: selection.range.lowerBound)
            tracks[i].split(at: selection.range.upperBound)
        }
    }

    /// Join clips within the selection.
    mutating func join() throws {
        let (range, idx) = try requireRange()
        for i in idx { tracks[i].join(range) }
    }

    /// Copy the selection of each selected track into a new track at the same time position.
    mutating func duplicate() throws {
        let (range, idx) = try requireRange()
        var newIDs: Set<UUID> = []
        for i in idx {
            let src = tracks[i]
            let t = Track(name: src.name + " copy", channelCount: src.channelCount,
                          clips: [Clip(name: src.name, start: range.lowerBound, samples: src.render(range))],
                          gainDB: src.gainDB, pan: src.pan, colorIndex: tracks.count)
            tracks.append(t)
            newIDs.insert(t.id)
        }
        selection.trackIDs = newIDs
    }

    /// Insert silence of `frames` at the cursor in every selected track.
    mutating func insertSilence(frames: Int) throws {
        let idx = selectedTrackIndices
        guard !idx.isEmpty else { throw EditError.noTracksSelected }
        let at = selection.cursor
        if !selection.isEmpty { for i in idx { tracks[i].remove(selection.range, shift: true) } }
        for i in idx {
            tracks[i].insert(.silence(channels: tracks[i].channelCount, frames: frames), at: at)
        }
        selection.range = at..<(at + frames)
    }

    // MARK: Tracks

    @discardableResult
    mutating func addTrack(name: String? = nil, channels: Int = 1) -> UUID {
        let t = Track(name: name ?? "Audio \(tracks.count + 1)", channelCount: channels, colorIndex: tracks.count)
        tracks.append(t)
        return t.id
    }

    mutating func removeTracks(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        selection.trackIDs.subtract(ids)
    }

    mutating func moveTrack(from: Int, to: Int) {
        guard tracks.indices.contains(from), tracks.indices.contains(to) else { return }
        let t = tracks.remove(at: from)
        tracks.insert(t, at: to)
    }

    /// Mix the selected tracks (or all audible tracks) into one new track ("Mix and Render").
    mutating func mixAndRender(channels: Int = 2) {
        let ids = selection.trackIDs.isEmpty ? Set(tracks.map(\.id)) : selection.trackIDs
        let end = tracks.filter { ids.contains($0.id) }.map(\.endFrame).max() ?? 0
        guard end > 0 else { return }
        let mix = Mixer(project: self, trackIDs: ids).render(0..<end, channels: channels)
        let t = Track(name: "Mix", channelCount: channels, clips: [Clip(name: "Mix", start: 0, samples: mix)],
                      colorIndex: tracks.count)
        removeTracks(ids)
        tracks.append(t)
        selection.trackIDs = [t.id]
    }

    /// Import audio as a new track at `frame` (resampled to the project rate).
    @discardableResult
    mutating func importAudio(_ audio: PlanarAudio, sampleRate rate: Double, name: String, at frame: Int = 0) -> UUID {
        let data = resampled(audio, from: rate)
        let ch = min(2, max(1, data.count))
        let t = Track(name: name, channelCount: ch,
                      clips: [Clip(name: name, start: frame, samples: conform(data, channels: ch))],
                      colorIndex: tracks.count)
        tracks.append(t)
        return t.id
    }

    // MARK: Labels

    mutating func addLabel(_ text: String, range: Range<Int>? = nil) {
        labels.append(TimelineLabel(range: range ?? selection.range, text: text))
        labels.sort { $0.range.lowerBound < $1.range.lowerBound }
    }

    private mutating func shiftLabels(after frame: Int, by delta: Int, removing removed: Range<Int>) {
        labels.removeAll { removed.lowerBound <= $0.range.lowerBound && $0.range.upperBound <= removed.upperBound && !removed.isEmpty && !$0.range.isEmpty }
        for i in labels.indices where labels[i].range.lowerBound >= frame {
            let r = labels[i].range
            labels[i].range = (r.lowerBound + delta)..<(r.upperBound + delta)
        }
    }

    /// Resample planar audio from `rate` to the project rate (no-op when equal).
    func resampled(_ audio: PlanarAudio, from rate: Double) -> PlanarAudio {
        guard rate > 0, abs(rate - sampleRate) > 0.5 else { return audio }
        return audio.map { DSP.resample($0, speed: rate / sampleRate) }
    }
}

/// Linear undo/redo history of whole-project snapshots.
/// Swift arrays are copy-on-write, so unchanged clips share storage between states,
/// mirroring how the desktop editor shares sample blocks between undo states.
public struct History: Sendable {
    public struct Entry: Sendable {
        public var project: Project
        public var description: String
    }

    public private(set) var entries: [Entry]
    public private(set) var index: Int
    public var limit: Int

    public init(initial: Project, limit: Int = 100) {
        entries = [Entry(project: initial, description: "Created")]
        index = 0
        self.limit = max(2, limit)
    }

    public var current: Project { entries[index].project }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < entries.count - 1 }
    public var undoDescription: String? { canUndo ? entries[index].description : nil }
    public var redoDescription: String? { canRedo ? entries[index + 1].description : nil }

    public mutating func push(_ project: Project, _ description: String) {
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(project: project, description: description))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
    }

    /// Replace the current state without a new undo step (e.g. selection changes).
    public mutating func amend(_ project: Project) { entries[index].project = project }

    public mutating func undo() -> Project? {
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    public mutating func redo() -> Project? {
        guard canRedo else { return nil }
        index += 1
        return current
    }
}
