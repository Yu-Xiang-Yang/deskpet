import Foundation

/// One Server-Sent Event.
struct SSEEvent: Equatable {
    var event: String?
    var data: String
}

/// Splits a byte stream into lines. UTF-8 is decoded only for complete lines, so multi-byte
/// characters that straddle network chunks are reassembled correctly.
struct SSELineSplitter {
    private var buffer = [UInt8]()

    /// Returns a line (without the terminator) when `byte` completes one.
    mutating func append(_ byte: UInt8) -> String? {
        if byte == UInt8(ascii: "\n") {
            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        buffer.append(byte)
        return nil
    }

    /// The trailing partial line at end of stream, if any.
    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Assembles lines into events following the SSE specification: `event:` and `data:` fields
/// accumulate until a blank line dispatches the event; lines starting with `:` are comments.
struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    /// Dispatches any pending event at end of stream.
    mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

extension URLSession {
    /// Streams the SSE events of a POST request. Non-2xx responses throw `LLMError.http` with the body.
    func sseEvents(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 64_000 { break } }
                        throw LLMError.http(status: status, body: String(decoding: body, as: UTF8.self))
                    }
                    var splitter = SSELineSplitter()
                    var parser = SSEParser()
                    for try await byte in bytes {
                        if let line = splitter.append(byte), let event = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    if let line = splitter.finish(), let event = parser.consume(line: line) { continuation.yield(event) }
                    if let event = parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum LLMError: LocalizedError {
    case missingKey
    case http(status: Int, body: String)
    case refusal(String?)
    case api(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return tr("尚未设置 API key，请在“设置”中填写。", "No API key is set. Add one in Settings.")
        case .http(let status, let body):
            let message = (try? JSON.parse(body))?["error"]?["message"]?.string
                ?? (try? JSON.parse(body))?["error"]?.string
                ?? String(body.prefix(300))
            return "HTTP \(status): \(message)"
        case .refusal(let category):
            return tr("模型拒绝了该请求", "The model declined the request") + (category.map { " (\($0))" } ?? "")
        case .api(let message):
            return message
        case .badResponse(let detail):
            return tr("无法解析模型响应：", "Unreadable model response: ") + detail
        }
    }
}
