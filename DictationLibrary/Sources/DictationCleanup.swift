import Foundation
import SpeechKit

public struct DictationCleanupContext: Sendable {
    public let imageData: Data
    public let mimeType: String

    public init(imageData: Data, mimeType: String) {
        self.imageData = imageData
        self.mimeType = mimeType
    }
}

public struct DictationCleanupOutput: Sendable {
    public let text: String
    public let kind: DictationResultKind
    public let model: String
    public let contextWasUsed: Bool
}

public enum DictationCleanup {
    public static let model = "gemini-3.5-flash"

    public static func clean(text: String, plan: DictationPlan, access: SpeechProviderAccess, context: DictationCleanupContext? = nil) async throws -> DictationCleanupOutput {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, plan.context != .terminal, plan.cleanupEnabled else {
            return DictationCleanupOutput(text: text, kind: .providerOutput, model: plan.effectiveModel, contextWasUsed: false)
        }
        guard ["minimal", "low", "medium", "high"].contains(plan.thinkingLevel.lowercased()) else { throw DictationLibraryError.invalidConfiguration }
        let upstream = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = try access.request(upstream: upstream)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var parts: [[String: Any]] = []
        if let context {
            guard ["image/png", "image/jpeg", "image/webp"].contains(context.mimeType) else { throw DictationLibraryError.invalidConfiguration }
            parts.append(["inlineData": ["mimeType": context.mimeType, "data": context.imageData.base64EncodedString()]])
        }
        parts.append(["text": "TRANSCRIPT:\n\(text)"])
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": parts]],
            "systemInstruction": ["parts": [["text": instruction(plan: plan)]]],
            "generationConfig": [
                "thinkingConfig": ["thinkingLevel": plan.thinkingLevel.lowercased()],
                "responseMimeType": "application/json",
                "responseJsonSchema": ["type": "object", "properties": ["kind": ["type": "string", "enum": ["cleanup", "answer"]], "text": ["type": "string"]], "required": ["kind", "text"], "additionalProperties": false]
            ]
        ])
        let (data, response) = try await SpeechKitURLSessionFactory.batchSession(for: access).data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpeechKitError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw access.failure(response, body: String(data: data, encoding: .utf8) ?? "")
        }
        let responseValue = try JSONDecoder().decode(Response.self, from: data)
        let output = responseValue.candidates.first?.content.parts.filter { $0.thought != true }.compactMap(\.text).joined() ?? ""
        guard let bytes = output.data(using: .utf8) else { throw SpeechKitError.invalidResponse }
        let value = try JSONDecoder().decode(Output.self, from: bytes)
        guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.kind == "cleanup" || value.kind == "answer" else { throw SpeechKitError.invalidResponse }
        return DictationCleanupOutput(text: value.text, kind: value.kind == "answer" ? .answer : (context == nil ? .cleanup : .contextualOutput), model: model, contextWasUsed: context != nil)
    }

    public static func instruction(plan: DictationPlan) -> String {
        var rules = ["Clean raw speech transcripts: remove fillers, false starts and repetition, preserving intent, meaning and facts. Return JSON with kind and text. Use kind cleanup for the cleaned transcript. If the speaker explicitly addresses the post-processing model and requests an answer, use kind answer and answer briefly. Never classify an answer as something the speaker said."]
        if let language = plan.outputLanguage, !language.isEmpty { rules.append("Write the cleaned output in \(language).") }
        else { rules.append("Preserve the spoken language.") }
        if !plan.dictionary.isEmpty { rules.append("Preserve these personal terms' spelling and casing when spoken; never invent terms: \(plan.dictionary.joined(separator: ", ")).") }
        return rules.joined(separator: " ")
    }

    private struct Output: Decodable { let kind: String; let text: String }
    private struct Response: Decodable {
        let candidates: [Candidate]
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String?; let thought: Bool? }
    }
}
