import Foundation

public enum GeminiSpeechVoice: String, CaseIterable, Sendable {
    case zephyr = "Zephyr"
    case puck = "Puck"
    case charon = "Charon"
    case kore = "Kore"
    case fenrir = "Fenrir"
    case leda = "Leda"
    case orus = "Orus"
    case aoede = "Aoede"
    case callirrhoe = "Callirrhoe"
    case autonoe = "Autonoe"
    case enceladus = "Enceladus"
    case iapetus = "Iapetus"
    case umbriel = "Umbriel"
    case algieba = "Algieba"
    case despina = "Despina"
    case erinome = "Erinome"
    case algenib = "Algenib"
    case rasalgethi = "Rasalgethi"
    case laomedeia = "Laomedeia"
    case achernar = "Achernar"
    case alnilam = "Alnilam"
    case schedar = "Schedar"
    case gacrux = "Gacrux"
    case pulcherrima = "Pulcherrima"
    case achird = "Achird"
    case zubenelgenubi = "Zubenelgenubi"
    case vindemiatrix = "Vindemiatrix"
    case sadachbia = "Sadachbia"
    case sadaltager = "Sadaltager"
    case sulafat = "Sulafat"
}

public enum GeminiSpeechSynthesisModel: Sendable, Equatable {
    case flash31Preview
    case custom(String)

    public var id: String {
        switch self {
        case .flash31Preview:
            "gemini-3.1-flash-tts-preview"
        case .custom(let id):
            id
        }
    }
}

public enum GeminiSpeechSynthesisTransport: Sendable, Equatable {
    /// The faster streaming transport for the current Gemini 3.1 TTS preview.
    case generateContent

    /// The newer Interactions API transport.
    case interactions
}

public struct GeminiSpeechSynthesisConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let retryCount: Int
    public let transport: GeminiSpeechSynthesisTransport

    public init(
        access: SpeechProviderAccess,
        retryCount: Int = 1,
        transport: GeminiSpeechSynthesisTransport = .generateContent
    ) throws {
        guard retryCount >= 0 else {
            throw SpeechKitError.invalidConfiguration("Retry count cannot be negative")
        }

        self.access = access
        self.retryCount = retryCount
        self.transport = transport
    }
}

public struct GeminiSpeechSynthesisOptions: SpeechSynthesisGenerationOptions {
    public let model: GeminiSpeechSynthesisModel
    public let voice: GeminiSpeechVoice
    public let instructions: String?

    public init(
        model: GeminiSpeechSynthesisModel = .flash31Preview,
        voice: GeminiSpeechVoice = .achird,
        instructions: String? = nil
    ) throws {
        guard !model.id.isEmpty else {
            throw SpeechKitError.invalidConfiguration("Gemini model is required")
        }

        self.model = model
        self.voice = voice
        self.instructions = instructions
    }
}

public final class GeminiSpeechSynthesisProvider: SpeechSynthesisProvider {
    public typealias GenerationOptions = GeminiSpeechSynthesisOptions

    public let id = "gemini"

    private let configuration: GeminiSpeechSynthesisConfiguration
    private let session: URLSession
    private let endpointOverride: URL?

    public init(configuration: GeminiSpeechSynthesisConfiguration) {
        self.configuration = configuration
        self.session = SpeechKitURLSessionFactory.streamingSession(for: configuration.access)
        self.endpointOverride = nil
    }

    init(
        configuration: GeminiSpeechSynthesisConfiguration,
        session: URLSession,
        endpoint: URL? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.endpointOverride = endpoint
    }

    public func synthesize(
        _ request: SpeechSynthesisRequest<GeminiSpeechSynthesisOptions>
    ) -> SpeechAudioStream {
        SpeechAudioStream { continuation in
            let task = Task {
                do {
                    try validate(request)
                    for attempt in 0...configuration.retryCount {
                        do {
                            let didReceiveAudio = try await streamAttempt(
                                request,
                                continuation: continuation
                            )
                            guard didReceiveAudio else {
                                throw SpeechKitError.invalidResponse
                            }
                            continuation.finish()
                            return
                        } catch SpeechKitError.httpFailure(let statusCode, let body)
                            where isRetryableHTTPFailure(statusCode: statusCode, body: body)
                                && attempt < configuration.retryCount {
                            try await Task.sleep(for: .milliseconds(150))
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

extension GeminiSpeechSynthesisProvider {
    private func isRetryableHTTPFailure(statusCode: Int, body: String) -> Bool {
        if statusCode == 500 { return true }
        return statusCode == 400
            && body.contains("INVALID_ARGUMENT")
            && body.contains("Request contains an invalid argument.")
    }

    private struct GenerateContentRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                let text: String
            }

            let parts: [Part]
        }

        struct GenerationConfiguration: Encodable {
            struct SpeechConfiguration: Encodable {
                struct VoiceConfiguration: Encodable {
                    struct PrebuiltVoiceConfiguration: Encodable {
                        let voiceName: String
                    }

                    let prebuiltVoiceConfig: PrebuiltVoiceConfiguration
                }

                let voiceConfig: VoiceConfiguration
            }

            let responseModalities = ["AUDIO"]
            let speechConfig: SpeechConfiguration
        }

        let contents: [Content]
        let generationConfig: GenerationConfiguration
    }

    private struct InteractionRequest: Encodable {
        struct ResponseFormat: Encodable {
            let type = "audio"
        }

        struct GenerationConfiguration: Encodable {
            struct SpeechConfiguration: Encodable {
                let voice: String
            }

            let speechConfig: [SpeechConfiguration]

            enum CodingKeys: String, CodingKey {
                case speechConfig = "speech_config"
            }
        }

        let model: String
        let input: String
        let responseFormat = ResponseFormat()
        let generationConfig: GenerationConfiguration
        let stream = true
        let store = false

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case responseFormat = "response_format"
            case generationConfig = "generation_config"
            case stream
            case store
        }
    }

    private struct InteractionStreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String
            let data: String?
        }

        struct ProviderError: Decodable {
            let message: String
            let code: String?
        }

        let eventType: String?
        let delta: Delta?
        let error: ProviderError?

        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case delta
            case error
        }
    }

    private struct GenerateContentStreamEvent: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    struct InlineData: Decodable {
                        let mimeType: String
                        let data: String
                    }

                    let inlineData: InlineData?
                }

                let parts: [Part]
            }

            let content: Content
        }

        struct ProviderError: Decodable {
            let message: String
        }

        let candidates: [Candidate]?
        let error: ProviderError?
    }

    private func validate(_ request: SpeechSynthesisRequest<GeminiSpeechSynthesisOptions>) throws {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechKitError.invalidRequest("Speech text is empty")
        }
    }

    func makeURLRequest(
        for request: SpeechSynthesisRequest<GeminiSpeechSynthesisOptions>
    ) throws -> URLRequest {
        var urlRequest = try configuration.access.request(upstream: try endpoint(for: request.options.model))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        switch configuration.transport {
        case .generateContent:
            let body = GenerateContentRequest(
                contents: [.init(parts: [.init(text: synthesisPrompt(for: request))])],
                generationConfig: .init(
                    speechConfig: .init(
                        voiceConfig: .init(
                            prebuiltVoiceConfig: .init(
                                voiceName: request.options.voice.rawValue
                            )
                        )
                    )
                )
            )
            urlRequest.httpBody = try JSONEncoder().encode(body)
        case .interactions:
            let body = InteractionRequest(
                model: request.options.model.id,
                input: synthesisPrompt(for: request),
                generationConfig: .init(
                    speechConfig: [.init(voice: request.options.voice.rawValue)]
                )
            )
            urlRequest.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }
        return urlRequest
    }

    private func endpoint(for model: GeminiSpeechSynthesisModel) throws -> URL {
        if let endpointOverride { return endpointOverride }

        switch configuration.transport {
        case .generateContent:
            var components = URLComponents(
                string: "https://generativelanguage.googleapis.com/v1beta"
            )
            components?.path += "/models/\(model.id):streamGenerateContent"
            components?.queryItems = [.init(name: "alt", value: "sse")]
            guard let url = components?.url else {
                throw SpeechKitError.invalidConfiguration("Invalid Gemini model identifier")
            }
            return url
        case .interactions:
            guard let url = URL(
                string: "https://generativelanguage.googleapis.com/v1beta/interactions"
            ) else {
                throw SpeechKitError.invalidConfiguration("Invalid Gemini endpoint")
            }
            return url
        }
    }

    private func synthesisPrompt(
        for request: SpeechSynthesisRequest<GeminiSpeechSynthesisOptions>
    ) -> String {
        var sections = [
            "Synthesize speech from the transcript below. Speak only the transcript content; do not read these labels or instructions aloud."
        ]
        if let instructions = request.options.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            sections.append("DIRECTOR'S NOTES:\n\(instructions)")
        }
        sections.append("TRANSCRIPT:\n\(request.text)")
        return sections.joined(separator: "\n\n")
    }

    private func streamAttempt(
        _ request: SpeechSynthesisRequest<GeminiSpeechSynthesisOptions>,
        continuation: SpeechAudioStream.Continuation
    ) async throws -> Bool {
        let (bytes, response) = try await session.bytes(for: makeURLRequest(for: request))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = try await responseBody(from: bytes)
            throw configuration.access.failure(httpResponse, body: body)
        }

        var eventName: String?
        var dataLines: [String] = []
        var didReceiveAudio = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if try yieldEvent(named: eventName, dataLines: dataLines, to: continuation) {
                    didReceiveAudio = true
                }
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("event:") {
                if try yieldEvent(named: eventName, dataLines: dataLines, to: continuation) {
                    didReceiveAudio = true
                }
                dataLines.removeAll(keepingCapacity: true)
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if configuration.transport == .generateContent {
                    if try yieldEvent(named: nil, dataLines: [dataLine], to: continuation) {
                        didReceiveAudio = true
                    }
                } else {
                    dataLines.append(dataLine)
                }
            }
        }

        if try yieldEvent(named: eventName, dataLines: dataLines, to: continuation) {
            didReceiveAudio = true
        }
        return didReceiveAudio
    }

    private func yieldEvent(
        named eventName: String?,
        dataLines: [String],
        to continuation: SpeechAudioStream.Continuation
    ) throws -> Bool {
        guard !dataLines.isEmpty else { return false }
        let payload = dataLines.joined(separator: "\n")
        guard payload != "[DONE]" else { return false }
        guard let data = payload.data(using: .utf8) else {
            throw SpeechKitError.invalidResponse
        }

        switch configuration.transport {
        case .generateContent:
            let event = try JSONDecoder().decode(GenerateContentStreamEvent.self, from: data)
            if let error = event.error {
                throw SpeechKitError.providerFailure(error.message)
            }
            let encodedAudio = event.candidates?
                .lazy
                .flatMap(\.content.parts)
                .compactMap(\.inlineData)
                .first(where: { $0.mimeType.hasPrefix("audio/l16") })?
                .data
            guard let encodedAudio else { return false }
            return try yieldAudio(encodedAudio, to: continuation)
        case .interactions:
            let event = try JSONDecoder().decode(InteractionStreamEvent.self, from: data)
            let resolvedName = event.eventType ?? eventName
            if resolvedName == "error" {
                let detail = [event.error?.code, event.error?.message]
                    .compactMap { $0 }
                    .joined(separator: ": ")
                throw SpeechKitError.providerFailure(
                    detail.isEmpty ? "Gemini stream failed" : detail
                )
            }

            guard resolvedName == "step.delta", event.delta?.type == "audio",
                  let encodedAudio = event.delta?.data else {
                return false
            }
            return try yieldAudio(encodedAudio, to: continuation)
        }
    }

    private func yieldAudio(
        _ encodedAudio: String,
        to continuation: SpeechAudioStream.Continuation
    ) throws -> Bool {
        guard let audio = Data(base64Encoded: encodedAudio), !audio.isEmpty else {
            throw SpeechKitError.invalidResponse
        }
        continuation.yield(.init(data: audio, format: .pcm16Mono24kHz))
        return true
    }

    private func responseBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        data.reserveCapacity(1_024)
        for try await byte in bytes.prefix(64 * 1_024) {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
