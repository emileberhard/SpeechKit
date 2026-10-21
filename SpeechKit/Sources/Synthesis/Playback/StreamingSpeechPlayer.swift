import Accelerate
import AVFAudio
import Foundation

public actor StreamingSpeechPlayer {
    private static let scheduledBufferDuration = 0.2

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var configuredFormat: SpeechAudioFormat?
    private var pendingBufferCount = 0
    private var queuedAudioDuration = 0.0
    private var streamFinished = false
    private var playbackStarted = false
    private var playbackPrepared = false
    private var underrunCount = 0
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var playbackID = UUID()
    private var playbackAnalyzer: SpeechPlaybackAnalyzer?
    private var playbackVisualizationHandler: (@Sendable (SpeechPlaybackVisualization) async -> Void)?
    private var isPlaybackMeterInstalled = false

    public init() {
        engine.attach(playerNode)
    }

    public func play(
        _ stream: SpeechAudioStream,
        buffering: SpeechPlaybackConfiguration.Buffering = .automatic,
        onPlaybackStarted: (@Sendable () async -> Void)? = nil,
        onPlaybackVisualizationChanged: (@Sendable (SpeechPlaybackVisualization) async -> Void)? = nil
    ) async throws {
        try await play(
            stream,
            buffering: buffering,
            prepareForPlayback: nil,
            onPlaybackStarted: onPlaybackStarted,
            onPlaybackVisualizationChanged: onPlaybackVisualizationChanged
        )
    }

    func play(
        _ stream: SpeechAudioStream,
        buffering: SpeechPlaybackConfiguration.Buffering,
        prepareForPlayback: (@Sendable () async throws -> Void)?,
        onPlaybackStarted: (@Sendable () async -> Void)?,
        onPlaybackVisualizationChanged: (@Sendable (SpeechPlaybackVisualization) async -> Void)?
    ) async throws {
        stopPlayback(resumingWith: CancellationError())
        let activePlaybackID = UUID()
        playbackID = activePlaybackID
        playbackVisualizationHandler = onPlaybackVisualizationChanged
        playbackAnalyzer = onPlaybackVisualizationChanged == nil ? nil : SpeechPlaybackAnalyzer()

        try await withTaskCancellationHandler {
            try await playStream(
                stream,
                playbackID: activePlaybackID,
                buffering: buffering,
                prepareForPlayback: prepareForPlayback,
                onPlaybackStarted: onPlaybackStarted
            )
        } onCancel: {
            Task {
                await self.stop(playbackID: activePlaybackID)
            }
        }
    }

    public func stop() {
        stopPlayback(resumingWith: CancellationError())
    }
}

private extension StreamingSpeechPlayer {
    func playStream(
        _ stream: SpeechAudioStream,
        playbackID: UUID,
        buffering: SpeechPlaybackConfiguration.Buffering,
        prepareForPlayback: (@Sendable () async throws -> Void)?,
        onPlaybackStarted: (@Sendable () async -> Void)?
    ) async throws {
        let clock = ContinuousClock()
        var firstChunkAt: ContinuousClock.Instant?
        var receivedAudioDuration = 0.0
        var accumulatedData = Data()
        var accumulatedFormat: SpeechAudioFormat?
        var didScheduleAudio = false
        var didNotifyPlaybackStarted = false

        do {
            try validate(buffering)

            for try await chunk in stream {
                try Task.checkCancellation()
                try validate(chunk)
                firstChunkAt = firstChunkAt ?? clock.now
                receivedAudioDuration += duration(of: chunk)

                if let accumulatedFormat, accumulatedFormat != chunk.format {
                    try scheduleAccumulatedData(
                        &accumulatedData,
                        format: accumulatedFormat,
                        playbackID: playbackID
                    )
                    didScheduleAudio = true
                }
                accumulatedFormat = chunk.format
                accumulatedData.append(chunk.data)

                if duration(of: accumulatedData, format: chunk.format) >= Self.scheduledBufferDuration {
                    try scheduleAccumulatedData(
                        &accumulatedData,
                        format: chunk.format,
                        playbackID: playbackID
                    )
                    didScheduleAudio = true
                }

                if try await startPlaybackIfReady(
                    playbackID: playbackID,
                    buffering: buffering,
                    receivedAudioDuration: receivedAudioDuration,
                    deliveryDuration: firstChunkAt?.duration(to: clock.now).seconds ?? 0,
                    prepareForPlayback: prepareForPlayback
                ), !didNotifyPlaybackStarted {
                    didNotifyPlaybackStarted = true
                    await onPlaybackStarted?()
                }
            }

            try Task.checkCancellation()
            if let accumulatedFormat, !accumulatedData.isEmpty {
                try scheduleAccumulatedData(
                    &accumulatedData,
                    format: accumulatedFormat,
                    playbackID: playbackID
                )
                didScheduleAudio = true
            }
            guard didScheduleAudio else {
                throw SpeechKitError.invalidResponse
            }

            streamFinished = true
            if try await startPlaybackIfReady(
                playbackID: playbackID,
                buffering: buffering,
                receivedAudioDuration: receivedAudioDuration,
                deliveryDuration: firstChunkAt?.duration(to: clock.now).seconds ?? 0,
                prepareForPlayback: prepareForPlayback
            ), !didNotifyPlaybackStarted {
                didNotifyPlaybackStarted = true
                await onPlaybackStarted?()
            }

            if pendingBufferCount > 0 {
                try await waitForPlaybackToFinish()
            } else {
                stopEngine()
            }
        } catch {
            stopPlayback(playbackID: playbackID, resumingWith: error)
            throw error
        }
    }

    func validate(_ buffering: SpeechPlaybackConfiguration.Buffering) throws {
        guard case .streaming(let duration) = buffering else { return }
        guard duration >= .zero else {
            throw SpeechKitError.invalidConfiguration(
                "Minimum buffered duration cannot be negative"
            )
        }
    }

    func validate(_ chunk: SpeechAudioChunk) throws {
        guard !chunk.data.isEmpty else { return }
        guard chunk.format.sampleFormat == .signedInteger16LittleEndian else {
            throw SpeechKitError.invalidConfiguration("Unsupported speech sample format")
        }
        guard chunk.format.channelCount == 1 else {
            throw SpeechKitError.invalidConfiguration(
                "Streaming playback currently supports mono audio"
            )
        }

        let bytesPerFrame = MemoryLayout<Int16>.size
        guard chunk.format.sampleRate > 0,
              chunk.data.count.isMultiple(of: bytesPerFrame) else {
            throw SpeechKitError.invalidResponse
        }
    }

    func scheduleAccumulatedData(
        _ data: inout Data,
        format: SpeechAudioFormat,
        playbackID: UUID
    ) throws {
        guard !data.isEmpty else { return }
        let scheduledData = data
        data.removeAll(keepingCapacity: true)
        try schedule(
            SpeechAudioChunk(data: scheduledData, format: format),
            playbackID: playbackID
        )
    }

    func schedule(_ chunk: SpeechAudioChunk, playbackID: UUID) throws {
        guard self.playbackID == playbackID else {
            throw CancellationError()
        }
        guard !chunk.data.isEmpty else { return }
        try configureIfNeeded(for: chunk.format)

        let frameCount = AVAudioFrameCount(chunk.data.count / MemoryLayout<Int16>.size)
        guard let audioFormat = audioFormat(for: chunk.format),
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount),
              let channelData = buffer.int16ChannelData else {
            throw SpeechKitError.invalidConfiguration(
                "Unable to create a PCM playback buffer"
            )
        }

        chunk.data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                channelData[0].update(
                    from: source.assumingMemoryBound(to: Int16.self),
                    count: chunk.data.count / MemoryLayout<Int16>.size
                )
            }
        }
        buffer.frameLength = frameCount

        let scheduledDuration = Double(frameCount) / chunk.format.sampleRate
        pendingBufferCount += 1
        queuedAudioDuration += scheduledDuration
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task {
                await self?.bufferDidPlay(
                    playbackID: playbackID,
                    duration: scheduledDuration
                )
            }
        }
    }

    func startPlaybackIfReady(
        playbackID: UUID,
        buffering: SpeechPlaybackConfiguration.Buffering,
        receivedAudioDuration: Double,
        deliveryDuration: Double,
        prepareForPlayback: (@Sendable () async throws -> Void)?
    ) async throws -> Bool {
        guard !playbackStarted, pendingBufferCount > 0 else { return false }
        guard SpeechStreamBufferingDecision.shouldStart(
            buffering: buffering,
            streamFinished: streamFinished,
            receivedAudioDuration: receivedAudioDuration,
            queuedAudioDuration: queuedAudioDuration,
            deliveryDuration: deliveryDuration,
            underrunCount: underrunCount
        ) else { return false }

        if !playbackPrepared {
            try await prepareForPlayback?()
            guard self.playbackID == playbackID else { throw CancellationError() }
            playbackPrepared = true
        }

        if !engine.isRunning {
            try installPlaybackMeter(playbackID: playbackID)
            engine.prepare()
            try engine.start()
        }
        playerNode.play()
        playbackStarted = true
        return true
    }

    func configureIfNeeded(for format: SpeechAudioFormat) throws {
        guard configuredFormat != format else { return }
        guard pendingBufferCount == 0 else {
            throw SpeechKitError.invalidResponse
        }
        guard let avFormat = audioFormat(for: format) else {
            throw SpeechKitError.invalidConfiguration("Invalid speech audio format")
        }

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
        configuredFormat = format
    }

    func audioFormat(for format: SpeechAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        )
    }

    func duration(of chunk: SpeechAudioChunk) -> Double {
        duration(of: chunk.data, format: chunk.format)
    }

    func duration(of data: Data, format: SpeechAudioFormat) -> Double {
        let frameCount = data.count / (MemoryLayout<Int16>.size * format.channelCount)
        return Double(frameCount) / format.sampleRate
    }

    func waitForPlaybackToFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            playbackContinuation = continuation
        }
    }

    func bufferDidPlay(playbackID: UUID, duration: Double) {
        guard self.playbackID == playbackID else { return }
        pendingBufferCount = max(0, pendingBufferCount - 1)
        queuedAudioDuration = max(0, queuedAudioDuration - duration)

        if streamFinished, pendingBufferCount == 0 {
            stopEngine()
            let continuation = playbackContinuation
            playbackContinuation = nil
            continuation?.resume()
        } else if pendingBufferCount == 0 {
            playerNode.pause()
            playbackStarted = false
            underrunCount += 1
        }
    }

    func stop(playbackID: UUID) {
        stopPlayback(playbackID: playbackID, resumingWith: CancellationError())
    }

    func stopEngine() {
        let visualizationHandler = playbackVisualizationHandler
        playbackVisualizationHandler = nil
        playbackAnalyzer = nil
        if isPlaybackMeterInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            isPlaybackMeterInstalled = false
        }
        playerNode.stop()
        engine.stop()
        streamFinished = false
        playbackStarted = false
        playbackPrepared = false
        if let visualizationHandler {
            Task {
                await visualizationHandler(.silence)
            }
        }
    }

    func stopPlayback(playbackID expectedPlaybackID: UUID? = nil, resumingWith error: Error) {
        guard expectedPlaybackID == nil || playbackID == expectedPlaybackID else { return }
        playbackID = UUID()
        stopEngine()
        pendingBufferCount = 0
        queuedAudioDuration = 0
        underrunCount = 0
        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume(throwing: error)
    }

    func installPlaybackMeter(playbackID: UUID) throws {
        guard playbackVisualizationHandler != nil, !isPlaybackMeterInstalled else { return }

        let mixer = engine.mainMixerNode
        let sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        let bufferSize = AVAudioFrameCount(max(Int(sampleRate * 0.1), 100))

        if #available(iOS 27.0, macOS 27.0, *) {
            try mixer.installAudioTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: nil
            ) { [weak self] buffer, _ in
                Task {
                    await self?.emitPlaybackVisualization(
                        buffer: buffer,
                        playbackID: playbackID
                    )
                }
            }
        } else {
            mixer.installTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: nil
            ) { [weak self] buffer, _ in
                guard let samples = buffer.floatChannelData?.pointee else { return }
                let copiedSamples = Array(
                    UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
                )
                let sampleRate = buffer.format.sampleRate
                Task {
                    await self?.emitPlaybackVisualization(
                        samples: copiedSamples,
                        sampleRate: sampleRate,
                        playbackID: playbackID
                    )
                }
            }
        }
        isPlaybackMeterInstalled = true
    }

    @available(iOS 27.0, macOS 27.0, *)
    func emitPlaybackVisualization(
        buffer: AVReadOnlyAudioPCMBuffer,
        playbackID: UUID
    ) async {
        guard self.playbackID == playbackID,
              let playbackVisualizationHandler,
              let playbackAnalyzer,
              case .float(let samples) = buffer.channelData(0) else { return }
        let visualization = samples.withUnsafeBufferPointer {
            playbackAnalyzer.analyze(
                samples: $0,
                sampleRate: buffer.format.sampleRate
            )
        }
        await playbackVisualizationHandler(visualization)
    }

    func emitPlaybackVisualization(
        samples: [Float],
        sampleRate: Double,
        playbackID: UUID
    ) async {
        guard self.playbackID == playbackID,
              let playbackVisualizationHandler,
              let playbackAnalyzer else { return }
        let visualization = samples.withUnsafeBufferPointer {
            playbackAnalyzer.analyze(samples: $0, sampleRate: sampleRate)
        }
        await playbackVisualizationHandler(visualization)
    }
}

enum SpeechPlaybackLevelMeter {
    static func normalizedLevel(samples: UnsafeBufferPointer<Float>) -> Float {
        guard let baseAddress = samples.baseAddress, !samples.isEmpty else { return 0 }

        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgv(baseAddress, 1, &peak, vDSP_Length(samples.count))

        return min(1, (rms * 0.7 + peak * 0.3) * 2.5)
    }
}

struct SpeechStreamBufferingDecision {
    private static let automaticProbeDuration = 0.4
    private static let automaticMinimumBufferDuration = 0.25
    private static let sustainableDeliveryRate = 1.1

    static func shouldStart(
        buffering: SpeechPlaybackConfiguration.Buffering,
        streamFinished: Bool,
        receivedAudioDuration: Double,
        queuedAudioDuration: Double,
        deliveryDuration: Double,
        underrunCount: Int
    ) -> Bool {
        if streamFinished { return true }

        switch buffering {
        case .automatic:
            guard receivedAudioDuration >= automaticProbeDuration,
                  deliveryDuration > 0 else { return false }
            let deliveryRate = receivedAudioDuration / deliveryDuration
            let minimumBufferDuration = automaticMinimumBufferDuration
                * pow(2, Double(underrunCount))
            return deliveryRate >= sustainableDeliveryRate
                && queuedAudioDuration >= minimumBufferDuration
        case .streaming(let minimumBufferedDuration):
            return queuedAudioDuration >= minimumBufferedDuration.seconds
        case .complete:
            return false
        }
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
