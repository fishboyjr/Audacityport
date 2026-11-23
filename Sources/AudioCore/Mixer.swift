import Foundation
import AudioDSP

/// Renders the audible mix of a project (gain, pan, mute, solo) to planar audio.
/// Used for playback, export and Mix and Render.
public struct Mixer: Sendable {
    public let project: Project
    public let trackIDs: Set<UUID>?

    public init(project: Project, trackIDs: Set<UUID>? = nil) {
        self.project = project
        self.trackIDs = trackIDs
    }

    /// Tracks that should be heard: solo overrides mute, as on the desktop.
    public var audibleTracks: [Track] {
        let pool = project.tracks.filter { trackIDs?.contains($0.id) ?? true }
        let soloed = pool.filter(\.isSolo)
        return soloed.isEmpty ? pool.filter { !$0.isMuted } : soloed
    }

    public func render(_ range: Range<Int>, channels: Int = 2) -> PlanarAudio {
        var out = PlanarAudio.silence(channels: channels, frames: range.count)
        guard !range.isEmpty else { return out }
        for track in audibleTracks {
            let src = track.render(range)
            let gain = track.linearGain
            for c in 0..<channels {
                let s = src[min(c, src.count - 1)]
                // A mono track feeding a stereo bus is panned; stereo tracks are balanced.
                s.withUnsafeBufferPointer { sp in
                    out[c].withUnsafeMutableBufferPointer { dp in
                        adsp_mix_into(dp.baseAddress, sp.baseAddress, range.count, gain, track.pan,
                                      Int32(c), Int32(channels))
                    }
                }
            }
        }
        return out
    }

    /// Peak level per output channel over a range (for meters / clipping warnings).
    public func peaks(_ range: Range<Int>, channels: Int = 2) -> [Float] {
        render(range, channels: channels).map { DSP.peak($0) }
    }
}
