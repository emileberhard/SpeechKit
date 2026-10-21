import Foundation
import Testing
@testable import SpeechKit

struct PCM16WAVFileTests {
    @Test func wrapsMonoPCM16InAValidWAVContainer() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = try PCM16WAVFile.data(pcmData: pcm, sampleRate: 16_000)

        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(wav.suffix(pcm.count) == pcm)
    }

    @Test func rejectsInvalidInputs() {
        #expect(throws: SpeechKitError.self) {
            _ = try PCM16WAVFile.data(pcmData: Data([0x00]), sampleRate: 0)
        }
        #expect(throws: SpeechKitError.self) {
            _ = try PCM16WAVFile.data(pcmData: Data(), sampleRate: 16_000)
        }
    }
}
