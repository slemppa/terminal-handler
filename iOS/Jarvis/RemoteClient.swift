import Foundation
import CoreGraphics

/// One answer from the Mac's `/jarvis/*` routes (see docs/jarvis-puhelin.md).
struct JobReply: Decodable, Equatable {
    var id: String
    var status: String
    var say: String?
    var reply: String?
    var step: String?
    var question: String?
    var options: [String]?
    var promptID: String?

    enum CodingKeys: String, CodingKey {
        case id, status, say, reply, step, question, options
        case promptID = "prompt_id"
    }

    var isWorking: Bool { status == "working" }
    var isPrompt: Bool { status == "prompt" }
}

enum RemoteError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Aseta ensin osoite ja API-avain."
        case .http(401, _): "API-avain ei kelpaa."
        case .http(let code, let message): "Mac vastasi virheellä \(code): \(message)"
        }
    }
}

struct RemoteClient {
    var baseURL: URL
    var apiKey: String

    func command(_ text: String) async throws -> JobReply {
        try await post("jarvis/command", ["text": text])
    }

    func status(_ id: String) async throws -> JobReply {
        try await post("jarvis/status", ["id": id])
    }

    func answer(job: String, prompt: String, choice: String) async throws -> JobReply {
        try await post("jarvis/answer", ["id": job, "prompt_id": prompt, "choice": choice])
    }

    // MARK: Screen

    /// One JPEG of the Mac's main display. Off until sharing is turned on
    /// on the Mac (403).
    func screenFrame(maxSide: Int, quality: Double) async throws -> ScreenFrame {
        let body = try JSONSerialization.data(withJSONObject: ["max_side": maxSide, "quality": quality])
        let (data, response) = try await send("jarvis/screen/frame", json: body, timeout: 10)
        func header(_ name: String) -> Double { Double(response.value(forHTTPHeaderField: name) ?? "") ?? 0 }
        return ScreenFrame(jpeg: data, screenSize: CGSize(width: header("X-Screen-Width"), height: header("X-Screen-Height")))
    }

    /// `body` is one of the shapes in `ScreenAPI` on the Mac, already JSON.
    func screenInput(_ body: Data) async throws {
        _ = try await send("jarvis/screen/input", json: body, timeout: 15)
    }

    // MARK: HTTP

    private func post(_ path: String, _ body: [String: String]) async throws -> JobReply {
        // The Mac waits up to 25 s per request.
        let (data, _) = try await send(path, json: try JSONEncoder().encode(body), timeout: 60)
        return try JSONDecoder().decode(JobReply.self, from: data)
    }

    private func send(_ path: String, json: Data, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = json
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200, let http else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw RemoteError.http(code, message)
        }
        return (data, http)
    }
}

struct ScreenFrame {
    var jpeg: Data
    /// The Mac's display in points.
    var screenSize: CGSize
}
