import XCTest
@testable import AudioCore

final class EditingTests: XCTestCase {
    private func ramp(_ n: Int, from start: Float = 0) -> [Float] { (0..<n).map { start + Float($0) } }

    private func project(frames: Int = 100) -> (Project, UUID) {
        var p = Project(sampleRate: 100)
        let id = p.importAudio([ramp(frames)], sampleRate: 100, name: "A")
        p.selection.trackIDs = [id]
        return (p, id)
    }

    func testCopyCutPaste() throws {
        var (p, _) = project()
        p.selection.range = 10..<20
        let clip = try p.cut()
        XCTAssertEqual(clip.tracks[0][0], ramp(10, from: 10))
        XCTAssertEqual(p.endFrame, 90)
        XCTAssertEqual(p.tracks[0].render(9..<11)[0], [9, 20])
        XCTAssertEqual(p.tracks[0].clips.count, 1, "deleting inside a clip keeps one clip")

        p.selection.range = 0..<0
        try p.paste(clip)
        XCTAssertEqual(p.endFrame, 100)
        XCTAssertEqual(p.tracks[0].render(0..<3)[0], [10, 11, 12])
        XCTAssertEqual(p.selection.range, 0..<10)
    }

    func testPasteReplacesSelection() throws {
        var (p, _) = project()
        let clip = Clipboard(tracks: [[[-1, -1]]], sampleRate: 100)
        p.selection.range = 50..<60
        try p.paste(clip)
        XCTAssertEqual(p.endFrame, 92)
        XCTAssertEqual(p.tracks[0].render(49..<53)[0], [49, -1, -1, 60])
    }

    func testPasteWithoutTrackCreatesTrack() throws {
        var (p, _) = project()
        p.selection = Selection(range: 5..<5, trackIDs: [])
        try p.paste(Clipboard(tracks: [[[1, 2, 3]]], sampleRate: 100))
        XCTAssertEqual(p.tracks.count, 2)
        XCTAssertEqual(p.tracks[1].render(5..<8)[0], [1, 2, 3])
    }

    func testSilenceTrimSplitJoin() throws {
        var (p, _) = project()
        p.selection.range = 10..<20
        try p.silenceSelection()
        XCTAssertEqual(p.tracks[0].render(9..<11)[0], [9, 0])
        XCTAssertEqual(p.endFrame, 100)

        try p.split()
        XCTAssertEqual(p.tracks[0].clips.count, 3)
        try p.trim()
        XCTAssertEqual(p.tracks[0].startFrame, 10)
        XCTAssertEqual(p.tracks[0].endFrame, 20)

        var (q, _) = project()
        q.selection.range = 30..<40
        try q.split()
        q.tracks[0].moveClip(q.tracks[0].clips[2].id, by: 10)
        XCTAssertEqual(q.tracks[0].clips[2].start, 50)
        q.selection.range = 0..<200
        try q.join()
        XCTAssertEqual(q.tracks[0].clips.count, 1)
        XCTAssertEqual(q.tracks[0].render(40..<50)[0], [Float](repeating: 0, count: 10))
    }

    func testDeleteAcrossGap() throws {
        var t = Track(name: "t", clips: [Clip(start: 0, samples: [ramp(10)]), Clip(start: 20, samples: [ramp(10, from: 100)])])
        t.remove(5..<25, shift: true)
        XCTAssertEqual(t.endFrame, 10)
        XCTAssertEqual(t.render(0..<10)[0], [0, 1, 2, 3, 4, 105, 106, 107, 108, 109])
    }

    func testUndoRedo() throws {
        var (p, _) = project()
        var h = History(initial: p)
        p.selection.range = 0..<50
        try p.delete()
        h.push(p, "Delete")
        XCTAssertEqual(h.undoDescription, "Delete")
        XCTAssertEqual(h.undo()?.endFrame, 100)
        XCTAssertEqual(h.redo()?.endFrame, 50)
        XCTAssertFalse(h.canRedo)
    }

    func testStereoConform() {
        let m = conform([[1, 1], [3, 3]], channels: 1)
        XCTAssertEqual(m, [[2, 2]])
        XCTAssertEqual(conform([[1]], channels: 2), [[1], [1]])
    }
}

final class EffectTests: XCTestCase {
    private func toneProject(seconds: Double = 1, amp: Float = 0.5) throws -> Project {
        var p = Project(sampleRate: 44_100)
        p.selection = Selection(range: 0..<0, trackIDs: [])
        var v = ToneGenerator().defaults
        v["duration"] = seconds
        v["amp"] = Double(amp)
        try p.apply(ToneGenerator(), values: v)
        return p
    }

    func testGenerateToneCreatesTrack() throws {
        let p = try toneProject()
        XCTAssertEqual(p.tracks.count, 1)
        XCTAssertEqual(p.endFrame, 44_100)
        XCTAssertEqual(DSP.peak(p.tracks[0].render(0..<44_100)[0]), 0.5, accuracy: 1e-3)
    }

    func testNormalizeAndAmplifyClipGuard() throws {
        var p = try toneProject()
        try p.apply(Normalize(), values: Normalize().defaults)
        XCTAssertEqual(DSP.peak(p.tracks[0].render(0..<p.endFrame)[0]), DSP.linear(-1), accuracy: 1e-3)
        var v = Amplify().defaults
        v["gain"] = 6
        XCTAssertThrowsError(try p.apply(Amplify(), values: v))
        v["clip"] = 1
        XCTAssertNoThrow(try p.apply(Amplify(), values: v))
    }

    func testChangeSpeedUpdatesLengthAndSelection() throws {
        var p = try toneProject()
        var v = ChangeSpeed().defaults
        v["percent"] = 100
        try p.apply(ChangeSpeed(), values: v)
        XCTAssertEqual(p.endFrame, 22_050)
        XCTAssertEqual(p.selection.range, 0..<22_050)
    }

    func testEffectNeedsSelection() throws {
        var p = try toneProject()
        p.selection.range = 0..<0
        XCTAssertThrowsError(try p.apply(Reverse(), values: EffectValues())) { e in
            XCTAssertEqual(e as? EditError, .noSelection)
        }
    }

    func testTruncateSilence() throws {
        let fs = 1000.0
        let loud = [Float](repeating: 0.5, count: 100)
        let quiet = [Float](repeating: 0, count: 2000)
        var v = TruncateSilence().defaults
        v["minimum"] = 0.5
        v["truncate"] = 0.2
        let out = try TruncateSilence().process([loud + quiet + loud], values: v, context: EffectContext(sampleRate: fs))
        XCTAssertEqual(out[0].count, 400)
    }

    func testNoiseReductionRequiresProfile() throws {
        var p = try toneProject()
        p.selection.range = 0..<1000
        XCTAssertThrowsError(try p.apply(NoiseReduction(), values: NoiseReduction().defaults))
        let prof = NoiseReduction.profile(from: p.tracks[0].render(0..<4096))
        XCTAssertEqual(prof.count, NoiseReduction.fftSize / 2 + 1)
        XCTAssertNoThrow(try p.apply(NoiseReduction(), values: NoiseReduction().defaults,
                                     context: EffectContext(sampleRate: p.sampleRate, noiseProfile: prof)))
    }

    func testEveryEffectRunsWithDefaults() throws {
        let ctx = EffectContext(sampleRate: 44_100, noiseProfile: [Float](repeating: 0.01, count: NoiseReduction.fftSize / 2 + 1))
        let input: PlanarAudio = [(0..<8820).map { sinf(Float($0) * 0.05) * 0.5 }, [Float](repeating: 0.1, count: 8820)]
        for e in EffectCatalog.all {
            let out = try e.process(input, values: e.defaults, context: ctx)
            XCTAssertEqual(out.count, 2, e.name)
            XCTAssertGreaterThan(out.frameCount, 0, e.name)
            XCTAssertTrue(out.allSatisfy { $0.count == out.frameCount }, e.name)
            XCTAssertTrue(out.joined().allSatisfy { $0.isFinite }, e.name)
        }
    }
}

final class MixerAndIOTests: XCTestCase {
    func testMuteSoloPan() {
        var p = Project(sampleRate: 10)
        p.tracks = [
            Track(name: "a", clips: [Clip(start: 0, samples: [[1, 1]])], pan: -1),
            Track(name: "b", clips: [Clip(start: 0, samples: [[0.5, 0.5]])]),
        ]
        var mix = Mixer(project: p).render(0..<2)
        XCTAssertEqual(mix[0][0], 1.5, accuracy: 1e-6)
        XCTAssertEqual(mix[1][0], 0.5, accuracy: 1e-6)
        p.tracks[1].isSolo = true
        mix = Mixer(project: p).render(0..<2)
        XCTAssertEqual(mix[0][0], 0.5, accuracy: 1e-6)
        p.tracks[1].isSolo = false
        p.tracks[1].isMuted = true
        mix = Mixer(project: p).render(0..<2)
        XCTAssertEqual(mix[1][0], 0, accuracy: 1e-6)
    }

    func testWAVRoundTrip() throws {
        let audio: PlanarAudio = [[0, 0.5, -0.5, 0.25], [0.1, 0.2, 0.3, 0.4]]
        for f in WAVCodec.SampleFormat.allCases {
            let d = WAVCodec.encode(audio, sampleRate: 48_000, format: f)
            let back = try WAVCodec.decode(d)
            XCTAssertEqual(back.sampleRate, 48_000)
            XCTAssertEqual(back.audio.count, 2)
            for c in 0..<2 { for i in 0..<4 { XCTAssertEqual(back.audio[c][i], audio[c][i], accuracy: 1e-4) } }
        }
        XCTAssertThrowsError(try WAVCodec.decode(Data("nope".utf8)))
    }

    func testProjectArchiveRoundTrip() throws {
        var p = Project(name: "Demo", sampleRate: 22_050)
        let id = p.importAudio([[0.1, 0.2, 0.3], [0.3, 0.2, 0.1]], sampleRate: 22_050, name: "Stereo", at: 7)
        p.addLabel("intro", range: 0..<5)
        p.tracks[0].gainDB = -3
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo.\(ProjectArchive.fileExtension)")
        try ProjectArchive.save(p, to: url)
        try ProjectArchive.save(p, to: url) // overwrite path
        let q = try ProjectArchive.load(from: url)
        XCTAssertEqual(q.tracks, p.tracks)
        XCTAssertEqual(q.labels, p.labels)
        XCTAssertEqual(q.tracks.first?.id, id)
        try? FileManager.default.removeItem(at: dir)
    }

    func testImportResamples() {
        var p = Project(sampleRate: 44_100)
        p.importAudio([[Float](repeating: 0.25, count: 22_050)], sampleRate: 22_050, name: "low")
        XCTAssertEqual(p.endFrame, 44_100)
        XCTAssertEqual(p.tracks[0].render(1000..<1001)[0][0], 0.25, accuracy: 1e-3)
    }
}

final class WaveformCacheTests: XCTestCase {
    func testPeaksMatchAtEveryZoomLevel() {
        let n = 300_000
        var samples = [Float](repeating: 0, count: n)
        samples[123_456] = 0.9
        samples[200_000] = -0.7
        let clip = Clip(start: 0, samples: [samples])
        let cache = WaveformCache()
        for columns in [3, 100, 2000, 100_000] {
            let p = cache.peaks(clip: clip, channel: 0, range: 0..<n, columns: columns)
            XCTAssertEqual(p.max.max(), 0.9, "columns \(columns)")
            XCTAssertEqual(p.min.min(), -0.7, "columns \(columns)")
        }
        // Content change invalidates the cache key.
        var edited = clip
        edited.samples[0][123_456] = 0
        XCTAssertNotEqual(edited.contentID, clip.contentID)
        XCTAssertEqual(cache.peaks(clip: edited, channel: 0, range: 0..<n, columns: 10).max.max(), 0)
    }
}
