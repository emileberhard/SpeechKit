import Foundation
import OSLog

struct SpeechUploadMetrics {
    private static let logger = Logger(subsystem: "SpeechKit", category: "SpeechUpload")

    static func log(task: URLSessionTask, metrics: URLSessionTaskMetrics, transport: SpeechRelayTransport?) {
        for (index, metric) in metrics.transactionMetrics.enumerated() {
            let origin = metric.request.url.map { "\($0.scheme ?? "unknown")://\($0.host() ?? "unknown")" } ?? "unknown"
            let message = "speech upload task=\(task.taskIdentifier) transaction=\(index) origin=\(origin) connect_ms=\(elapsed(metric.connectStartDate, metric.connectEndDate)) tls_ms=\(elapsed(metric.secureConnectionStartDate, metric.secureConnectionEndDate)) first_byte_ms=\(elapsed(metric.requestEndDate, metric.responseStartDate)) bytes_sent=\(metric.countOfRequestBodyBytesSent) reused=\(metric.isReusedConnection)"
            logger.notice("\(message, privacy: .public)")
            transport?.logUpload(message)
        }
    }

    private static func elapsed(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "not_started" }
        guard let end else { return "incomplete" }
        return String(Int(end.timeIntervalSince(start) * 1_000))
    }
}
