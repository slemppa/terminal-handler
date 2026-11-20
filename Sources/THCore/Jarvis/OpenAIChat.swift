import Foundation

/// The parts of an OpenAI chat completion request Jarvis cares about.
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var stream: Bool
    /// Role of the final message ("user", "tool", "assistant", …).
    public var lastRole: String
    /// Text of the final message when it is from the user: the dictated command.
    public var transcript: String?
    public var messageCount: Int
    public var toolCount: Int

    /// A client checking the provider works (FluidVoice sends one bare "test"
    /// without tools when its settings are saved). Answered without running Jarvis.
    public var isConnectionProbe: Bool {
        guard messageCount == 1, toolCount == 0, let transcript else { return false }
        let word = transcript.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["test", "testi", "ping", "hi", "hello"].contains(word)
    }

    public static func parse(_ body: Data) -> ChatRequest? {
        guard let json = JSONValue.parse(body), let messages = json["messages"]?.array else { return nil }
        let last = messages.last
        let role = last?["role"]?.string ?? ""
        var transcript: String?
        if role == "user", let content = last?["content"] {
            let text = messageText(content).trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = text.isEmpty ? nil : text
        }
        return ChatRequest(
            model: json["model"]?.string ?? JarvisAPI.modelID,
            stream: json["stream"]?.bool ?? false,
            lastRole: role,
            transcript: transcript,
            messageCount: messages.count,
            toolCount: json["tools"]?.array?.count ?? 0)
    }

    /// `content` is either a string or an array of parts (`{"type":"text","text":…}`).
    static func messageText(_ content: JSONValue) -> String {
        if let text = content.string { return text }
        return (content.array ?? []).compactMap { part in
            if let text = part.string { return text }
            guard (part["type"]?.string ?? "text") == "text" else { return nil }
            return part["text"]?.string
        }.joined(separator: "\n")
    }
}

/// Routing, access rules and response bodies of the local OpenAI-compatible endpoint.
public enum JarvisAPI {
    public static let modelID = "jarvis"
    public static let defaultPort: UInt16 = 8765

    public enum Route: Sendable, Equatable {
        case models
        case chatCompletions
        case notFound
    }

    /// Accepts both "<base>/models" and "<base>/chat/completions", whatever the base.
    public static func route(_ request: HTTPRequest) -> Route {
        let path = request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path
        if path.hasSuffix("/chat/completions") || path == "/chat/completions" { return .chatCompletions }
        if path.hasSuffix("/models") || path == "/models" { return .models }
        return .notFound
    }

    public enum Rejection: Sendable, Equatable {
        case browserOrigin
        case badHost
        case unauthorized
        case notJSON
        case method

        public var status: Int {
            switch self {
            case .unauthorized: 401
            case .method: 405
            default: 403
            }
        }

        public var message: String {
            switch self {
            case .browserOrigin: "Browser requests are not accepted"
            case .badHost: "Only localhost is accepted"
            case .unauthorized: "Invalid API key"
            case .notJSON: "Content-Type must be application/json"
            case .method: "Method not allowed"
            }
        }
    }

    /// Keeps web pages out: a page could otherwise POST to localhost and run
    /// commands on the Mac through Jarvis. Browsers always send `Origin` on
    /// cross-site POSTs and need a preflight for `application/json`, and the
    /// Host check stops DNS rebinding. The API key is the last line.
    public static func check(_ request: HTTPRequest, route: Route, apiKey: String?) -> Rejection? {
        if request.header("origin") != nil || request.header("sec-fetch-site") != nil { return .browserOrigin }
        if let host = request.header("host") {
            guard ["127.0.0.1", "localhost", "[::1]"].contains(hostName(host)) else { return .badHost }
        }
        switch route {
        case .models, .notFound:
            return request.method == "GET" ? nil : .method
        case .chatCompletions:
            guard request.method == "POST" else { return .method }
            guard (request.header("content-type") ?? "").lowercased().contains("application/json") else { return .notJSON }
            if let apiKey, !apiKey.isEmpty {
                let given = bearerToken(request.header("authorization")) ?? request.header("x-api-key")
                guard given == apiKey else { return .unauthorized }
            }
            return nil
        }
    }

    static func hostName(_ host: String) -> String {
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { return String(host[...end]).lowercased() }
        return host.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    // MARK: Bodies

    public static func modelsBody(created: Int = 1_795_000_000) -> Data {
        JSONValue.object([
            "object": .string("list"),
            "data": .array([.object([
                "id": .string(modelID),
                "object": .string("model"),
                "created": .int(Int64(created)),
                "owned_by": .string("terminal-handler"),
            ])]),
        ]).encoded()
    }

    public static func completionBody(id: String, model: String, created: Int, text: String) -> Data {
        JSONValue.object([
            "id": .string(id),
            "object": .string("chat.completion"),
            "created": .int(Int64(created)),
            "model": .string(model),
            "choices": .array([.object([
                "index": .int(0),
                "message": .object(["role": .string("assistant"), "content": .string(text)]),
                "finish_reason": .string("stop"),
            ])]),
            "usage": .object(["prompt_tokens": .int(0), "completion_tokens": .int(0), "total_tokens": .int(0)]),
        ]).encoded()
    }

    /// The whole SSE stream for one short answer: role, text, stop, `[DONE]`.
    public static func streamEvents(id: String, model: String, created: Int, text: String) -> Data {
        func chunk(_ delta: JSONValue, finish: JSONValue) -> String {
            let body = JSONValue.object([
                "id": .string(id),
                "object": .string("chat.completion.chunk"),
                "created": .int(Int64(created)),
                "model": .string(model),
                "choices": .array([.object(["index": .int(0), "delta": delta, "finish_reason": finish])]),
            ]).encoded()
            return "data: " + String(decoding: body, as: UTF8.self) + "\n\n"
        }
        var out = chunk(.object(["role": .string("assistant"), "content": .string("")]), finish: .null)
        out += chunk(.object(["content": .string(text)]), finish: .null)
        out += chunk(.object([:]), finish: .string("stop"))
        out += "data: [DONE]\n\n"
        return Data(out.utf8)
    }
}
