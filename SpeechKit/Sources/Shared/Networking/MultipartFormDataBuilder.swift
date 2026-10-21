import Foundation

struct MultipartFormDataBuilder {
    private let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        appendFileHeader(name: name, fileName: fileName, mimeType: mimeType)
        body.append(data)
        append("\r\n")
    }

    /// Framing for an audio part whose bytes arrive after the request starts.
    func streamingFile(name: String, fileName: String, mimeType: String) -> (prefix: Data, suffix: Data) {
        var builder = self
        builder.appendFileHeader(name: name, fileName: fileName, mimeType: mimeType)
        return (builder.build(), Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private mutating func appendFileHeader(name: String, fileName: String, mimeType: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
    }

    mutating func addArrayField(name: String, values: [String]) {
        for value in values {
            addField(name: name, value: value)
        }
    }

    mutating func finalize() {
        append("--\(boundary)--\r\n")
    }

    func build() -> Data {
        body
    }

    private mutating func append(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        body.append(data)
    }
}
