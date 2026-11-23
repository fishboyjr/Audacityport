import AudioCore
import Foundation

/// A generated sample project, for screenshots and first-run exploration.
extension EditorModel {
    func loadDemo() async {
        let rate = 44_100.0
        let seconds = 12.0
        let n = Int(rate * seconds)
        var rng = SystemRandomNumberGenerator()

        // "Voice": a harmonic tone shaped into syllable-like bursts.
        var voice = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let syllable = max(0, sin(2 * .pi * 2.3 * t)) * max(0, sin(2 * .pi * 0.21 * t + 0.4))
            let tone = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t) + 0.25 * sin(2 * .pi * 540 * t)
            voice[i] = Float(0.42 * syllable * tone) + Float.random(in: -0.004...0.004, using: &rng)
        }

        // "Music": a stereo pad with a slow swell, two slightly detuned channels.
        var left = [Float](repeating: 0, count: n), right = left
        for i in 0..<n {
            let t = Double(i) / rate
            let swell = 0.25 + 0.2 * sin(2 * .pi * 0.15 * t)
            let beat = pow(max(0, sin(2 * .pi * 2 * t)), 8) * 0.35
            left[i] = Float(swell * sin(2 * .pi * 110 * t) + beat * sin(2 * .pi * 55 * t))
            right[i] = Float(swell * sin(2 * .pi * 110.7 * t) + beat * sin(2 * .pi * 55 * t))
        }

        // "Room tone": quiet noise between two clips.
        let clipLen = Int(rate * 3.5)
        let noise = (0..<clipLen).map { _ in Float.random(in: -0.06...0.06, using: &rng) }

        var p = Project(name: "Demo Session", sampleRate: rate)
        let v = p.importAudio([voice], sampleRate: rate, name: "Voice")
        p.importAudio([left, right], sampleRate: rate, name: "Music")
        let roomID = p.addTrack(name: "Room Tone")
        if let i = p.trackIndex(roomID) {
            p.tracks[i].clips = [Clip(name: "Room Tone", start: Int(rate * 0.5), samples: [noise]),
                                 Clip(name: "Room Tone", start: Int(rate * 6.5), samples: [noise])]
            p.tracks[i].gainDB = -6
        }
        if let i = p.trackIndex(v) {
            var fade = p
            fade.selection = Selection(range: 0..<Int(rate * 1.5), trackIDs: [v])
            try? fade.apply(FadeIn(), values: FadeIn().defaults)
            p.tracks[i] = fade.tracks[i]
        }
        p.addLabel("Intro", range: 0..<0)
        p.addLabel("Verse", range: Int(rate * 4.2)..<Int(rate * 4.2))
        p.selection = Selection(range: Int(rate * 3.0)..<Int(rate * 5.5), trackIDs: [v])

        project = p
        resetHistory()
        isDirty = false
        playhead = Int(rate * 3.0)
        // Let the timeline report its width before fitting the zoom.
        try? await Task.sleep(for: .milliseconds(600))
        zoomToFit()
    }
}
