import Foundation

/// Convert audio to the requested channel count (mono→stereo duplicates, stereo→mono averages).
public func conform(_ audio: PlanarAudio, channels: Int) -> PlanarAudio {
    guard !audio.isEmpty else { return .silence(channels: channels, frames: 0) }
    if audio.count == channels { return audio }
    if channels == 1 {
        let n = audio.frameCount
        var mono = [Float](repeating: 0, count: n)
        let scale = 1 / Float(audio.count)
        for ch in audio { for i in 0..<n { mono[i] += ch[i] * scale } }
        return [mono]
    }
    // Upmix: repeat the available channels.
    return (0..<channels).map { audio[$0 % audio.count] }
}

public extension Track {
    /// Render the timeline range to contiguous audio (gaps between clips are silence).
    func render(_ range: Range<Int>) -> PlanarAudio {
        var out = PlanarAudio.silence(channels: channelCount, frames: range.count)
        guard !range.isEmpty else { return out }
        for clip in clips where clip.intersects(range) {
            let local = clip.localRange(range)
            let dst = clip.start + local.lowerBound - range.lowerBound
            for c in 0..<channelCount {
                let src = clip.samples[min(c, clip.channelCount - 1)]
                out[c].withUnsafeMutableBufferPointer { o in
                    src.withUnsafeBufferPointer { s in
                        for i in 0..<local.count { o[dst + i] = s[local.lowerBound + i] }
                    }
                }
            }
        }
        return out
    }

    /// Split any clip that strictly contains `frame` into two clips.
    mutating func split(at frame: Int) {
        var result: [Clip] = []
        for clip in clips {
            if frame > clip.start && frame < clip.end {
                let cut = frame - clip.start
                let left = Clip(id: clip.id, name: clip.name, start: clip.start, samples: clip.samples.map { Array($0[..<cut]) })
                let right = Clip(name: clip.name, start: frame, samples: clip.samples.map { Array($0[cut...]) })
                result.append(left)
                result.append(right)
            } else {
                result.append(clip)
            }
        }
        clips = result
        sortClips()
    }

    /// Remove audio in `range`. With `shift`, later material moves left to close the gap.
    mutating func remove(_ range: Range<Int>, shift: Bool) {
        guard !range.isEmpty else { return }
        // Deleting from the middle of one clip keeps it a single clip.
        if shift, let idx = clips.firstIndex(where: { $0.start <= range.lowerBound && $0.end >= range.upperBound }) {
            let lo = range.lowerBound - clips[idx].start
            for c in clips[idx].samples.indices {
                clips[idx].samples[c].removeSubrange(lo..<(lo + range.count))
            }
            for i in clips.indices where i != idx && clips[i].start >= range.upperBound {
                clips[i].start -= range.count
            }
            clips.removeAll { $0.length == 0 }
            return
        }
        split(at: range.lowerBound)
        split(at: range.upperBound)
        clips.removeAll { $0.start >= range.lowerBound && $0.end <= range.upperBound && $0.length > 0 }
        if shift {
            for i in clips.indices where clips[i].start >= range.upperBound {
                clips[i].start -= range.count
            }
        }
    }

    /// Insert audio at `frame`, pushing later material right.
    /// When the frame lies inside (or at the end of) a clip, the audio is spliced into that clip.
    mutating func insert(_ audio: PlanarAudio, at frame: Int, name: String = "") {
        let data = conform(audio, channels: channelCount)
        let n = data.frameCount
        guard n > 0 else { return }
        if let idx = clips.firstIndex(where: { frame > $0.start && frame <= $0.end }) {
            let cut = frame - clips[idx].start
            for c in 0..<channelCount {
                clips[idx].samples[c].insert(contentsOf: data[c], at: cut)
            }
            for i in clips.indices where i != idx && clips[i].start >= frame {
                clips[i].start += n
            }
        } else {
            for i in clips.indices where clips[i].start >= frame {
                clips[i].start += n
            }
            clips.append(Clip(name: name.isEmpty ? self.name : name, start: frame, samples: data))
        }
        sortClips()
    }

    /// Replace `range` with `audio` (which may differ in length; later clips shift accordingly).
    mutating func replace(_ range: Range<Int>, with audio: PlanarAudio) {
        let data = conform(audio, channels: channelCount)
        if let idx = clips.firstIndex(where: { $0.start <= range.lowerBound && $0.end >= range.upperBound }) {
            let lo = range.lowerBound - clips[idx].start
            let hi = range.upperBound - clips[idx].start
            for c in 0..<channelCount {
                clips[idx].samples[c].replaceSubrange(lo..<hi, with: data[c])
            }
            let delta = data.frameCount - range.count
            if delta != 0 {
                for i in clips.indices where i != idx && clips[i].start >= range.upperBound {
                    clips[i].start += delta
                }
            }
            sortClips()
        } else {
            remove(range, shift: true)
            insert(data, at: range.lowerBound)
        }
    }

    /// Overwrite existing clip audio inside the range with silence (gaps stay empty).
    mutating func silence(_ range: Range<Int>) {
        for i in clips.indices where clips[i].intersects(range) {
            let local = clips[i].localRange(range)
            for c in clips[i].samples.indices {
                clips[i].samples[c].replaceSubrange(local, with: repeatElement(0, count: local.count))
            }
        }
    }

    /// Keep only audio inside `range`, leaving it at its current position.
    mutating func trim(to range: Range<Int>) {
        let end = endFrame
        if range.upperBound < end { remove(range.upperBound..<end, shift: false) }
        let start = startFrame
        if range.lowerBound > start { remove(start..<range.lowerBound, shift: false) }
    }

    /// Join all clips intersecting `range` into one clip, filling gaps with silence.
    mutating func join(_ range: Range<Int>) {
        let hits = clips.filter { $0.intersects(range) }
        guard hits.count > 1, let lo = hits.map(\.start).min(), let hi = hits.map(\.end).max() else { return }
        let audio = render(lo..<hi)
        let name = hits[0].name
        clips.removeAll { $0.intersects(range) }
        clips.append(Clip(name: name, start: lo, samples: audio))
        sortClips()
    }

    /// Move a clip in time (clamped so it never starts before zero or overlaps neighbours).
    mutating func moveClip(_ id: UUID, by delta: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let cur = clips[i]
        var newStart = max(0, cur.start + delta)
        let len = cur.length
        let others = clips.filter { $0.id != id }
        if delta < 0, let prev = others.filter({ $0.end <= cur.start }).map(\.end).max() {
            newStart = max(newStart, prev)
        }
        if delta > 0, let next = others.filter({ $0.start >= cur.end }).map(\.start).min() {
            newStart = min(newStart, next - len)
        }
        clips[i].start = newStart
        sortClips()
    }
}
