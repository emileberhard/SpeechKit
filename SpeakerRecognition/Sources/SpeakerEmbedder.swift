import Accelerate
import CoreML
import Foundation

nonisolated struct SpeakerEmbedding: Codable, Equatable, Sendable {
    let values: [Float]

    init(normalizing values: [Float]) {
        let norm = sqrt(vDSP.sumOfSquares(values))
        self.values = norm > 0 ? vDSP.divide(values, norm) : values
    }

    func similarity(to other: SpeakerEmbedding) -> Float {
        vDSP.dot(values, other.values)
    }

    static func mean(of embeddings: [SpeakerEmbedding], weights: [Float]? = nil) -> SpeakerEmbedding? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for (index, embedding) in embeddings.enumerated() {
            sum = vDSP.add(multiplication: (embedding.values, weights?[index] ?? 1), sum)
        }
        return SpeakerEmbedding(normalizing: sum)
    }
}

nonisolated enum KaldiFilterbank {
    static let sampleRate = 16_000
    static let binCount = 80
    private static let windowLength = 400
    private static let hopLength = 160
    private static let fftLength = 512
    private static let spectrumLength = fftLength / 2 + 1
    private static let preemphasis: Float = 0.97
    private static let floor = Float.ulpOfOne
    private static let window = (0..<windowLength).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(windowLength - 1)) }
    private static let banks = makeBanks()

    static func frameCount(sampleCount: Int) -> Int {
        sampleCount < windowLength ? 0 : 1 + (sampleCount - windowLength) / hopLength
    }

    static func features(of samples: [Float]) throws -> [Float] {
        let frames = frameCount(sampleCount: samples.count)
        guard frames > 0 else { return [] }
        let transform = try vDSP.DiscreteFourierTransform(previous: nil, count: fftLength, direction: .forward,
                                                          transformType: .complexComplex, ofType: Float.self)
        let scaled = vDSP.multiply(Float(1 << 15), samples)
        let zeros = [Float](repeating: 0, count: fftLength)
        var real = [Float](repeating: 0, count: fftLength)
        var imaginary = [Float](repeating: 0, count: fftLength)
        var spectra = [Float](repeating: 0, count: frames * spectrumLength)
        var frame = [Float](repeating: 0, count: fftLength)
        for index in 0..<frames {
            let start = index * hopLength
            var raw = Array(scaled[start..<start + windowLength])
            raw = vDSP.add(-vDSP.mean(raw), raw)
            var emphasized = raw
            for sample in stride(from: windowLength - 1, through: 1, by: -1) {
                emphasized[sample] = raw[sample] - preemphasis * raw[sample - 1]
            }
            emphasized[0] = raw[0] - preemphasis * raw[0]
            frame.replaceSubrange(0..<windowLength, with: vDSP.multiply(emphasized, window))
            transform.transform(inputReal: frame, inputImaginary: zeros, outputReal: &real, outputImaginary: &imaginary)
            for bin in 0..<spectrumLength {
                spectra[index * spectrumLength + bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            }
        }
        var energies = [Float](repeating: 0, count: frames * binCount)
        vDSP_mmul(spectra, 1, banks, 1, &energies, 1, vDSP_Length(frames), vDSP_Length(binCount), vDSP_Length(spectrumLength))
        return energies.map { log(max($0, floor)) }
    }

    private static func makeBanks() -> [Float] {
        func mel(_ frequency: Double) -> Double { 1127 * log(1 + frequency / 700) }
        let low = mel(20), high = mel(Double(sampleRate) / 2)
        let delta = (high - low) / Double(binCount + 1)
        let binWidth = Double(sampleRate) / Double(fftLength)
        var banks = [Float](repeating: 0, count: spectrumLength * binCount)
        for bin in 0..<binCount {
            let left = low + Double(bin) * delta, center = left + delta, right = center + delta
            for fftBin in 0..<fftLength / 2 {
                let value = mel(binWidth * Double(fftBin))
                let weight = max(0, min((value - left) / (center - left), (right - value) / (right - center)))
                banks[fftBin * binCount + bin] = Float(weight)
            }
        }
        return banks
    }
}

actor SpeakerEmbedder {
    static let modelVersion = "wespeaker-voxceleb-resnet34-LM-f0c48c2-pal8"
    static let windowSamples = 10 * KaldiFilterbank.sampleRate
    private static let frames = KaldiFilterbank.frameCount(sampleCount: windowSamples)

    private let model: MLModel

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    static var bundledModelURL: URL? {
        Bundle.module.url(forResource: "SpeakerModel", withExtension: "mlmodelc")
    }

    static func requireModelURL() throws -> URL {
        guard let url = bundledModelURL else { throw VoiceFilterError.modelMissing }
        return url
    }

    func embedding(of samples: [Float]) throws -> SpeakerEmbedding {
        guard !samples.isEmpty else { throw SpeakerEmbedderError.emptyAudio }
        var window = samples
        while window.count < Self.windowSamples { window += samples }
        let features = try KaldiFilterbank.features(of: Array(window.prefix(Self.windowSamples)))
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.frames), NSNumber(value: KaldiFilterbank.binCount)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.initialize(from: features)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { throw SpeakerEmbedderError.missingOutput }
        return SpeakerEmbedding(normalizing: (0..<embedding.count).map { embedding[$0].floatValue })
    }
}

nonisolated enum SpeakerEmbedderError: Error, Equatable {
    case emptyAudio
    case missingOutput
}

nonisolated enum PCM16Samples {
    static func floats(_ data: Data) -> [Float] {
        var samples = [Int16](repeating: 0, count: data.count / 2)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var output = [Float](repeating: 0, count: samples.count)
        vDSP.convertElements(of: samples, to: &output)
        return vDSP.divide(output, 32_768)
    }
}
