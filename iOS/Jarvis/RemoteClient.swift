import Foundation

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

    private func post(_ path: String, _ body: [String: String]) async throws -> JobReply {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        // The Mac waits up to 25 s per request.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw RemoteError.http(code, message)
        }
        return try JSONDecoder().decode(JobReply.self, from: data)
    }
}
