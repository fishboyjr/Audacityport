import Foundation
import AudioDSP

/// Portable WAV codec (the iOS app uses AVFoundation for compressed formats).
public enum WAVCodec {
    public enum SampleFormat: String, CaseIterable, Codable, Sendable {
        case pcm16 = "16-bit PCM"
        case pcm24 = "24-bit PCM"
        case pcm32 = "32-bit PCM"
        case float32 = "32-bit float"

        var bits: Int32 { self == .pcm16 ? 16 : self == .pcm24 ? 24 : 32 }
        var isFloat: Int32 { self == .float32 ? 1 : 0 }
    }

    public struct Decoded: Sendable {
        public var audio: PlanarAudio
        public var sampleRate: Double
    }

    public enum WAVError: Error, LocalizedError {
        case invalidFile
        case unsupportedFormat
        public var errorDescription: String? {
            self == .invalidFile ? "Not a valid WAV file." : "Unsupported WAV sample format."
        }
    }

    public static func decode(_ data: Data) throws -> Decoded {
        try data.withUnsafeBytes { raw -> Decoded in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw WAVError.invalidFile }
            var info = adsp_wav_info()
            let offset = adsp_wav_parse(base, raw.count, &info)
            guard offset > 0, info.channels > 0 else { throw WAVError.invalidFile }
            let frames = Int(info.frames)
            var channels = PlanarAudio.silence(channels: Int(info.channels), frames: frames)
            // Collect stable pointers to every channel buffer for the C decoder.
            var pointers: [UnsafeMutablePointer<Float>?] = []
            var storage: [UnsafeMutableBufferPointer<Float>] = []
            for _ in 0..<Int(info.channels) {
                let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, frames))
                storage.append(buf)
                pointers.append(buf.baseAddress)
            }
            defer { storage.forEach { $0.deallocate() } }
            let status = pointers.withUnsafeMutableBufferPointer { p in
                adsp_wav_decode(base, raw.count, &info, offset, p.baseAddress)
            }
            guard status == 0 else { throw WAVError.unsupportedFormat }
            for c in 0..<channels.count { channels[c] = Array(storage[c].prefix(frames)) }
            return Decoded(audio: channels, sampleRate: Double(info.sample_rate))
        }
    }

    public static func encode(_ audio: PlanarAudio, sampleRate: Double, format: SampleFormat = .pcm16) -> Data {
        let ch = audio.count, frames = audio.frameCount
        let size = adsp_wav_encoded_size(Int32(ch), frames, format.bits)
        var out = Data(count: size)
        var ptrs: [UnsafePointer<Float>?] = []
        var copies: [UnsafeMutableBufferPointer<Float>] = []
        for c in audio {
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, frames))
            _ = b.initialize(from: c)
            copies.append(b)
            ptrs.append(UnsafePointer(b.baseAddress))
        }
        defer { copies.forEach { $0.deallocate() } }
        let written = out.withUnsafeMutableBytes { o -> Int in
            ptrs.withUnsafeBufferPointer { p in
                adsp_wav_encode(p.baseAddress, Int32(ch), frames, Int32(sampleRate), format.bits, format.isFloat,
                                o.bindMemory(to: UInt8.self).baseAddress, size)
            }
        }
        return out.prefix(written)
    }
}

/// Project package on disk: `Name.wavproj/` containing `project.json` and one raw float file per clip channel.
/// Like the desktop project format, audio lives beside a small manifest so saves are fast and robust.
public enum ProjectArchive {
    public static let fileExtension = "wavproj"
    static let manifestName = "project.json"
    static let audioFolder = "audio"

    struct Manifest: Codable {
        var version = 1
        var name: String
        var sampleRate: Double
        var labels: [TimelineLabel]
        var tracks: [TrackEntry]
    }

    struct TrackEntry: Codable {
        var id: UUID, name: String, channelCount: Int, gainDB: Float, pan: Float
        var isMuted: Bool, isSolo: Bool, colorIndex: Int
        var clips: [ClipEntry]
    }

    struct ClipEntry: Codable {
        var id: UUID, name: String, start: Int, length: Int, channels: Int
    }

    public static func save(_ project: Project, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp.appendingPathComponent(audioFolder), withIntermediateDirectories: true)
        var entries: [TrackEntry] = []
        for t in project.tracks {
            var clips: [ClipEntry] = []
            for c in t.clips {
                for (k, ch) in c.samples.enumerated() {
                    let data = ch.withUnsafeBufferPointer { Data(buffer: $0) }
                    try data.write(to: tmp.appendingPathComponent(audioFolder).appendingPathComponent("\(c.id.uuidString)-\(k).f32"))
                }
                clips.append(ClipEntry(id: c.id, name: c.name, start: c.start, length: c.length, channels: c.channelCount))
            }
            entries.append(TrackEntry(id: t.id, name: t.name, channelCount: t.channelCount, gainDB: t.gainDB, pan: t.pan,
                                      isMuted: t.isMuted, isSolo: t.isSolo, colorIndex: t.colorIndex, clips: clips))
        }
        let manifest = Manifest(name: project.name, sampleRate: project.sampleRate, labels: project.labels, tracks: entries)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: tmp.appendingPathComponent(manifestName))
        // Atomic swap so a crash mid-save never corrupts the previous version.
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).old-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: backup)
            do {
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try? fm.moveItem(at: backup, to: url) // restore the previous version
                throw error
            }
            try? fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    public static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url.appendingPathComponent(manifestName))
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        let audioDir = url.appendingPathComponent(audioFolder)
        let tracks: [Track] = try m.tracks.map { t in
            let clips: [Clip] = try t.clips.map { c in
                let samples: PlanarAudio = try (0..<c.channels).map { k in
                    let d = try Data(contentsOf: audioDir.appendingPathComponent("\(c.id.uuidString)-\(k).f32"))
                    var arr = [Float](repeating: 0, count: d.count / MemoryLayout<Float>.size)
                    _ = arr.withUnsafeMutableBytes { d.copyBytes(to: $0) }
                    return arr
                }
                return Clip(id: c.id, name: c.name, start: c.start, samples: samples)
            }
            return Track(id: t.id, name: t.name, channelCount: t.channelCount, clips: clips, gainDB: t.gainDB,
                         pan: t.pan, isMuted: t.isMuted, isSolo: t.isSolo, colorIndex: t.colorIndex)
        }
        return Project(name: m.name, sampleRate: m.sampleRate, tracks: tracks, labels: m.labels,
                       selection: Selection(range: 0..<0, trackIDs: []))
    }
}
