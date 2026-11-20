import Foundation

/// A parsed HTTP/1.1 request. Just enough for the local Jarvis endpoint.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path without the query string.
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPParseResult: Sendable, Equatable {
    /// Keep reading.
    case incomplete
    case complete(HTTPRequest)
    case invalid(String)
    case tooLarge
}

public enum HTTPRequestParser {
    /// Parses one request from the bytes read so far.
    public static func parse(_ data: Data, maxBodyBytes: Int = 8 << 20) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > 64 << 10 ? .invalid("header too long") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("header is not UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return parseChunked(data[headerEnd.upperBound...], method: String(requestLine[0]),
                                target: String(requestLine[1]), headers: headers, maxBodyBytes: maxBodyBytes)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("bad content-length") }
        guard length <= maxBodyBytes else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: String(requestLine[0]), path: pathOnly(String(requestLine[1])), headers: headers, body: body))
    }

    private static func parseChunked(_ rest: Data, method: String, target: String, headers: [String: String], maxBodyBytes: Int) -> HTTPParseResult {
        var body = Data()
        var cursor = rest.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = rest.range(of: crlf, in: cursor..<rest.endIndex) else { return .incomplete }
            let sizeText = String(decoding: rest[cursor..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16) else { return .invalid("bad chunk size") }
            let chunkStart = lineEnd.upperBound
            if size == 0 {
                return .complete(HTTPRequest(method: method, path: pathOnly(target), headers: headers, body: body))
            }
            guard rest.endIndex - chunkStart >= size + 2 else { return .incomplete }
            body.append(rest[chunkStart..<(chunkStart + size)])
            guard body.count <= maxBodyBytes else { return .tooLarge }
            cursor = chunkStart + size + 2
        }
    }

    private static func pathOnly(_ target: String) -> String {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        // Absolute-form targets ("http://host/v1/models").
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let url = URL(string: path) {
            path = url.path()
        }
        return path
    }
}

public enum HTTPResponse {
    public static func head(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    public static func full(status: Int, contentType: String = "application/json", body: Data) -> Data {
        var data = head(status: status, headers: [
            ("Content-Type", contentType),
            ("Content-Length", String(body.count)),
            ("Connection", "close"),
        ])
        data.append(body)
        return data
    }

    /// An OpenAI-shaped error body.
    public static func error(status: Int, message: String) -> Data {
        let body = JSONValue.object(["error": .object([
            "message": .string(message),
            "type": .string(status == 401 ? "invalid_request_error" : "server_error"),
        ])]).encoded()
        return full(status: status, body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}
