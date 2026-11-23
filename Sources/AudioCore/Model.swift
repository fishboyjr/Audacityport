import Foundation

/// Planar, 32-bit float audio: `channels[c][frame]`.
public typealias PlanarAudio = [[Float]]

public extension Array where Element == [Float] {
    /// Number of frames (length of the first channel).
    var frameCount: Int { first?.count ?? 0 }

    /// Planar silence.
    static func silence(channels: Int, frames: Int) -> PlanarAudio {
        Array(repeating: [Float](repeating: 0, count: max(0, frames)), count: max(1, channels))
    }
}

/// A contiguous piece of audio placed on a track's timeline.
/// Positions are integer sample frames at the project rate, which keeps edits sample-exact.
public struct Clip: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Timeline position of the first frame.
    public var start: Int
    public var samples: PlanarAudio {
        didSet { contentID = UUID() }
    }
    /// Changes whenever `samples` changes; keys waveform summary caches.
    public private(set) var contentID = UUID()

    public init(id: UUID = UUID(), name: String = "", start: Int, samples: PlanarAudio) {
        self.id = id
        self.name = name
        self.start = start
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey { case id, name, start, samples }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Int.self, forKey: .start)
        samples = try c.decode(PlanarAudio.self, forKey: .samples)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(start, forKey: .start)
        try c.encode(samples, forKey: .samples)
    }

    /// Equality ignores `contentID`; fast path when content identity matches.
    public static func == (a: Clip, b: Clip) -> Bool {
        a.id == b.id && a.name == b.name && a.start == b.start &&
            (a.contentID == b.contentID || a.samples == b.samples)
    }

    public var length: Int { samples.frameCount }
    public var end: Int { start + length }
    public var channelCount: Int { samples.count }

    public func intersects(_ range: Range<Int>) -> Bool {
        start < range.upperBound && end > range.lowerBound
    }

    /// Frames of this clip covering timeline `range` (clamped), as a local range.
    public func localRange(_ range: Range<Int>) -> Range<Int> {
        let lo = Swift.max(range.lowerBound, start) - start
        let hi = Swift.min(range.upperBound, end) - start
        return lo < hi ? lo..<hi : lo..<lo
    }

    /// Copy of the clip's audio inside timeline range.
    public func slice(_ range: Range<Int>) -> PlanarAudio {
        let r = localRange(range)
        return samples.map { Array($0[r]) }
    }
}

public struct Track: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var channelCount: Int
    public var clips: [Clip]
    /// Track gain in dB.
    public var gainDB: Float
    /// Balance, -1 (left) … +1 (right).
    public var pan: Float
    public var isMuted: Bool
    public var isSolo: Bool
    /// Index into the app's track colour palette.
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, channelCount: Int = 1, clips: [Clip] = [],
                gainDB: Float = 0, pan: Float = 0, isMuted: Bool = false, isSolo: Bool = false,
                colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.channelCount = max(1, min(2, channelCount))
        self.clips = clips
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.colorIndex = colorIndex
    }

    public var startFrame: Int { clips.map(\.start).min() ?? 0 }
    public var endFrame: Int { clips.map(\.end).max() ?? 0 }
    public var isEmpty: Bool { clips.allSatisfy { $0.length == 0 } }
    public var linearGain: Float { powf(10, gainDB / 20) }

    public mutating func sortClips() { clips.sort { $0.start < $1.start } }
}

/// Time selection across a set of tracks (like the desktop editor's selection).
public struct Selection: Codable, Equatable, Sendable {
    public var range: Range<Int>
    public var trackIDs: Set<UUID>

    public init(range: Range<Int> = 0..<0, trackIDs: Set<UUID> = []) {
        self.range = range
        self.trackIDs = trackIDs
    }

    public var isEmpty: Bool { range.isEmpty }
    /// A point selection is a cursor position (used for paste, record, generate).
    public var cursor: Int { range.lowerBound }

    public static func between(_ a: Int, _ b: Int, tracks: Set<UUID>) -> Selection {
        Selection(range: max(0, min(a, b))..<max(0, max(a, b)), trackIDs: tracks)
    }
}

/// A label marker on the timeline (point or region), like a label track.
public struct TimelineLabel: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var range: Range<Int>
    public var text: String

    public init(id: UUID = UUID(), range: Range<Int>, text: String) {
        self.id = id
        self.range = range
        self.text = text
    }
}

public struct Project: Codable, Equatable, Sendable {
    public static let defaultSampleRate: Double = 44_100

    public var name: String
    public var sampleRate: Double
    public var tracks: [Track]
    public var labels: [TimelineLabel]
    public var selection: Selection

    public init(name: String = "Untitled", sampleRate: Double = Project.defaultSampleRate,
                tracks: [Track] = [], labels: [TimelineLabel] = [], selection: Selection = Selection()) {
        self.name = name
        self.sampleRate = sampleRate
        self.tracks = tracks
        self.labels = labels
        self.selection = selection
    }

    public var endFrame: Int { tracks.map(\.endFrame).max() ?? 0 }
    public var duration: TimeInterval { seconds(endFrame) }

    public func seconds(_ frames: Int) -> TimeInterval { Double(frames) / sampleRate }
    public func frames(_ seconds: TimeInterval) -> Int { Int((seconds * sampleRate).rounded()) }

    public func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    public var selectedTrackIndices: [Int] {
        tracks.indices.filter { selection.trackIDs.contains(tracks[$0].id) }
    }
}
