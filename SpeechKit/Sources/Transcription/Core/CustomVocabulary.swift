import Foundation

enum CustomVocabulary {
    static func normalized(_ vocabulary: [String]) -> [String] {
        vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func promptSection(from vocabulary: [String]) -> String? {
        let terms = normalized(vocabulary)
        guard !terms.isEmpty else { return nil }

        let items = terms.map { "- \($0)" }.joined(separator: "\n")
        return "# Dictionary / Common Words\n\(items)"
    }
}
