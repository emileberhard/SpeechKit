import Accelerate
import Foundation
import os

nonisolated struct VoicedPieceSegmenter: Sendable {
    static let frameLength = 400
    static let hopLength = 160
    private static let warmupFrames = 50
    private static let closingGapFrames = 40
    private static let maximumPieceSamples = 10 * KaldiFilterbank.sampleRate
    private static let minimumPieceSamples = KaldiFilterbank.sampleRate
    private static let floorLevel: Float = -100
    private static let binWidth: Float = 0.5
    private static let speechShare: Float = 0.35

    private var histogram = [Int](repeating: 0, count: 200)
    private var evaluatedFrames = 0
    private var open: (first: Int, last: Int)?
    private var tail: [Float] = []

    mutating func append(_ samples: [Float]) -> [Range<Int>] {
        tail += samples
        var closed: [Range<Int>] = []
        var start = 0
        while start + Self.frameLength <= tail.count {
            let frame = evaluatedFrames
            evaluatedFrames += 1
            let level = 10 * log10(vDSP.meanSquare(tail[start..<start + Self.frameLength]) + 1e-10)
            if let piece = evaluate(frame: frame, isSpeech: classify(level, frame: frame)) { closed.append(piece) }
            start += Self.hopLength
        }
        tail.removeFirst(start)
        return closed
    }

    mutating func finish() -> Range<Int>? {
        defer { open = nil }
        return open.flatMap(Self.piece)
    }

    private mutating func classify(_ level: Float, frame: Int) -> Bool {
        let bin = min(histogram.count - 1, max(0, Int((level - Self.floorLevel) / Self.binWidth)))
        histogram[bin] += 1
        guard frame >= Self.warmupFrames else { return true }
        let low = percentile(0.05), high = percentile(0.95)
        return level > low + Self.speechShare * (high - low)
    }

    private func percentile(_ fraction: Float) -> Float {
        let target = fraction * Float(evaluatedFrames)
        var cumulative = 0
        for (bin, count) in histogram.enumerated() {
            cumulative += count
            if Float(cumulative) >= target { return Self.floorLevel + (Float(bin) + 0.5) * Self.binWidth }
        }
        return 0
    }

    private mutating func evaluate(frame: Int, isSpeech: Bool) -> Range<Int>? {
        guard let piece = open else {
            if isSpeech { open = (frame, frame) }
            return nil
        }
        if isSpeech {
            guard frame * Self.hopLength + Self.frameLength - piece.first * Self.hopLength > Self.maximumPieceSamples else {
                open = (piece.first, frame)
                return nil
            }
            open = (frame, frame)
            return Self.piece(piece)
        }
        guard frame - piece.last >= Self.closingGapFrames else { return nil }
        open = nil
        return Self.piece(piece)
    }

    private static func piece(_ frames: (first: Int, last: Int)) -> Range<Int>? {
        let range = frames.first * hopLength..<frames.last * hopLength + frameLength
        return range.count >= minimumPieceSamples ? range : nil
    }
}

nonisolated struct VoicedPiece: Sendable {
    let samples: Range<Int>
    let embedding: SpeakerEmbedding
}

nonisolated final class VoiceWatch: Sendable {
    static let maximumSamples = 600 * KaldiFilterbank.sampleRate

    private enum Input: Sendable {
        case audio(Data)
        case limitReached
    }

    private let input: AsyncStream<Input>.Continuation
    private let admittedBytes = OSAllocatedUnfairLock(initialState: 0)
    private let listening: Task<VoiceRecording, any Error>

    init(modelURL: URL, profile: SpeakerEmbedding?) {
        let (stream, input) = AsyncStream<Input>.makeStream()
        self.input = input
        listening = Task { try await Self.listen(to: stream, modelURL: modelURL, profile: profile) }
    }

    deinit { cancel() }

    func append(_ pcm16: Data) {
        admittedBytes.withLock { count in
            guard count <= Self.maximumSamples * 2 else { return }
            guard pcm16.count <= Self.maximumSamples * 2 - count else {
                count = Self.maximumSamples * 2 + 1
                input.yield(.limitReached)
                input.finish()
                return
            }
            count += pcm16.count
            input.yield(.audio(pcm16))
        }
    }

    func finish() { input.finish() }

    func cancel() {
        input.finish()
        listening.cancel()
    }

    var recording: VoiceRecording {
        get async throws { try await listening.value }
    }

    @concurrent private static func listen(to stream: AsyncStream<Input>, modelURL: URL, profile: SpeakerEmbedding?) async throws -> VoiceRecording {
        var listener = VoiceListener(embedder: try SpeakerEmbedder(modelURL: modelURL), profile: profile)
        for await chunk in stream {
            try Task.checkCancellation()
            switch chunk {
            case .audio(let pcm): try await listener.append(pcm)
            case .limitReached: listener.exceedLimit()
            }
        }
        try Task.checkCancellation()
        return try await listener.finish()
    }
}

nonisolated struct VoiceListener: Sendable {
    private let embedder: SpeakerEmbedder
    private var pcm = PCM16Audio()
    private var segmenter = VoicedPieceSegmenter()
    private var pieces: [VoicedPiece] = []
    private var isComplete = true

    init(embedder: SpeakerEmbedder, profile: SpeakerEmbedding?) {
        self.embedder = embedder
    }

    mutating func append(_ chunk: Data) async throws {
        guard isComplete else { return }
        guard pcm.sampleCount + chunk.count / 2 <= VoiceWatch.maximumSamples else {
            exceedLimit()
            return
        }
        pcm.append(chunk)
        for piece in segmenter.append(PCM16Samples.floats(chunk)) {
            pieces.append(VoicedPiece(samples: piece, embedding: try await embedder.embedding(of: pcm.samples(in: piece))))
        }
    }

    mutating func exceedLimit() {
        isComplete = false
        pcm = PCM16Audio()
        pieces = []
    }

    mutating func finish() async throws -> VoiceRecording {
        guard isComplete else { return VoiceRecording(audio: SpeakerAudio(embedder: embedder, pcm: pcm), pieces: [], isComplete: false) }
        if let piece = segmenter.finish() {
            pieces.append(VoicedPiece(samples: piece, embedding: try await embedder.embedding(of: pcm.samples(in: piece))))
        }
        return VoiceRecording(audio: SpeakerAudio(embedder: embedder, pcm: pcm), pieces: pieces, isComplete: true)
    }
}

nonisolated struct VoiceRecording: Sendable {
    static let minimumLearningSamples = 5 * KaldiFilterbank.sampleRate

    let audio: SpeakerAudio
    let pieces: [VoicedPiece]
    let isComplete: Bool

    var otherVoiceHeard: Bool {
        guard pieces.count >= 2 else { return false }
        return pieces.indices.contains { index in
            var others = pieces
            others.remove(at: index)
            guard let reference = SpeakerEmbedding.mean(of: others.map(\.embedding), weights: others.map { Float($0.samples.count) }) else {
                return false
            }
            return pieces[index].embedding.similarity(to: reference) < VoiceFilter.sameVoiceThreshold
        }
    }

    var requestsLabels: Bool { otherVoiceHeard }
    var containsMixedVoices: Bool { otherVoiceHeard }

    func learningCandidate() async throws -> SpeakerEmbedding? {
        guard isComplete, !containsMixedVoices, pieces.reduce(0, { $0 + $1.samples.count }) >= Self.minimumLearningSamples else { return nil }
        return try await audio.embedding(of: pieces.map(\.samples))
    }
}

nonisolated struct PCM16Audio: Sendable {
    private var chunks: [Data] = []
    private var starts: [Int] = []
    private(set) var sampleCount = 0

    init() {}

    init(_ pcm: Data) { append(pcm) }

    mutating func append(_ pcm: Data) {
        guard pcm.count >= 2 else { return }
        chunks.append(pcm)
        starts.append(sampleCount)
        sampleCount += pcm.count / 2
    }

    func samples(in range: Range<Int>) -> [Float] {
        let range = range.clamped(to: 0..<sampleCount)
        guard !range.isEmpty else { return [] }
        var first = starts.lastIndex { $0 <= range.lowerBound } ?? 0
        var bytes = Data(capacity: range.count * 2)
        while first < chunks.count, starts[first] < range.upperBound {
            let chunk = chunks[first]
            let lower = max(range.lowerBound - starts[first], 0) * 2
            let upper = min(range.upperBound - starts[first], chunk.count / 2) * 2
            bytes.append(chunk[chunk.startIndex + lower..<chunk.startIndex + upper])
            first += 1
        }
        return PCM16Samples.floats(bytes)
    }
}

nonisolated struct SpeakerAudio: Sendable {
    let embedder: SpeakerEmbedder
    let pcm: PCM16Audio

    func embedding(of ranges: [Range<Int>]) async throws -> SpeakerEmbedding {
        var audio: [Float] = []
        for range in ranges where audio.count < SpeakerEmbedder.windowSamples {
            audio += pcm.samples(in: range.lowerBound..<min(range.upperBound, range.lowerBound + SpeakerEmbedder.windowSamples - audio.count))
        }
        return try await embedder.embedding(of: audio)
    }
}
