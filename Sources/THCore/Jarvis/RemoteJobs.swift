import Foundation
import Synchronization

// MARK: - Remote commands (iPhone Shortcut over Tailscale)

/// A question Jarvis waits on, shown and answered on the phone.
public struct RemotePrompt: Sendable, Equatable {
    /// "<pending request id>#<question index>".
    public var id: String
    public var question: String
    public var options: [String]
    /// What the phone reads aloud, when the question itself is not for the ear
    /// (a shell command); nil reads the question.
    public var spoken: String?

    public init(id: String, question: String, options: [String], spoken: String? = nil) {
        self.id = id
        self.question = question
        self.options = options
        self.spoken = spoken
    }

    public static func id(request: UUID, index: Int) -> String { "\(request.uuidString)#\(index)" }

    /// Splits an id made by `id(request:index:)`.
    public static func parse(_ id: String) -> (request: UUID, index: Int)? {
        let parts = id.split(separator: "#")
        guard parts.count == 2, let request = UUID(uuidString: String(parts[0])), let index = Int(parts[1]), index >= 0 else { return nil }
        return (request, index)
    }

    public static let allow = "Salli"
    public static let deny = "Kiellä"

    /// Only an explicit yes allows; anything else denies.
    public static func isAllow(_ choice: String) -> Bool {
        let word = choice.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["salli", "allow", "kyllä", "joo", "yes"].contains(word)
    }
}

public enum RemoteJobState: Sendable, Equatable {
    /// Waiting behind another command.
    case queued
    /// Claude works; the text is the latest tool step, if any.
    case working(String?)
    /// Jarvis needs an answer before it can go on.
    case prompt(RemotePrompt)
    case done(String)
    case failed(String)

    /// The phone has something to do: speak, or answer.
    public var needsPhone: Bool {
        switch self {
        case .prompt, .done, .failed: true
        case .queued, .working: false
        }
    }

    public var isFinal: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }
}

/// Commands sent from the phone, shared between the HTTP threads (which
/// wait on them) and the main actor (which updates them).
public final class RemoteJobs: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var state: RemoteJobState
        /// Grows on every change, so a waiter can tell an old prompt from a new one.
        public var version: Int
    }

    private struct Job {
        var state: RemoteJobState
        var version: Int
        var updatedAt: Date
    }

    /// Finished jobs are forgotten after this long.
    public static let keepFor: TimeInterval = 60 * 60

    private let jobs = Mutex<[String: Job]>([:])

    public init() {}

    public func create(now: Date = .now) -> String {
        let id = "job-" + UUID().uuidString.prefix(13).lowercased()
        jobs.withLock { jobs in
            jobs = jobs.filter { now.timeIntervalSince($0.value.updatedAt) < Self.keepFor }
            jobs[id] = Job(state: .queued, version: 0, updatedAt: now)
        }
        return id
    }

    /// A finished job never changes again; an unchanged state is not a change.
    public func update(_ id: String, _ state: RemoteJobState, now: Date = .now) {
        jobs.withLock { jobs in
            guard var job = jobs[id], !job.state.isFinal, job.state != state else { return }
            job.state = state
            job.version += 1
            job.updatedAt = now
            jobs[id] = job
        }
    }

    public func snapshot(_ id: String) -> Snapshot? {
        jobs.withLock { jobs in jobs[id].map { Snapshot(state: $0.state, version: $0.version) } }
    }

    /// Blocks the calling thread until the job needs the phone (and, with
    /// `version`, has changed since it), or until `timeout`. nil for an
    /// unknown job. Long polling keeps the Shortcut's loop short.
    public func wait(_ id: String, after version: Int? = nil, timeout: TimeInterval, poll: TimeInterval = 0.25) -> Snapshot? {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            guard let snapshot = snapshot(id) else { return nil }
            let changed = version.map { snapshot.version > $0 } ?? true
            if changed && snapshot.state.needsPhone { return snapshot }
            if Date.now >= deadline { return snapshot }
            Thread.sleep(forTimeInterval: poll)
        }
    }
}

/// Request and response bodies of the phone's routes. Every response has
/// the same shape, so the Shortcut runs one loop:
/// `status` "working" → POST /jarvis/status again; "prompt" → choose from
/// `options` and POST /jarvis/answer; "done" or "failed" → speak `say`.
/// `say` is missing exactly while the phone must ask again, so a Shortcut
/// can branch on "has any value" without comparing text.
public enum RemoteAPI {
    /// How long one request waits for something to happen. Below the
    /// Shortcut's own timeout for "Get Contents of URL".
    public static let waitSeconds: TimeInterval = 25

    public static func commandText(_ body: Data) -> String? {
        guard let json = JSONValue.parse(body) else { return nil }
        let text = (json["text"]?.string ?? json["command"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func jobID(_ body: Data) -> String? {
        JSONValue.parse(body)?["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    public struct AnswerBody: Sendable, Equatable {
        public var jobID: String
        public var promptID: String
        public var choice: String
    }

    public static func answer(_ body: Data) -> AnswerBody? {
        guard let json = JSONValue.parse(body),
              let job = json["id"]?.string, !job.isEmpty,
              let prompt = json["prompt_id"]?.string, !prompt.isEmpty else { return nil }
        let choice = json["choice"]?.string ?? json["answer"]?.string ?? ""
        return AnswerBody(jobID: job, promptID: prompt, choice: choice)
    }

    public static func body(jobID: String, state: RemoteJobState) -> Data {
        var fields: [String: JSONValue] = ["id": .string(jobID)]
        switch state {
        case .queued:
            fields["status"] = .string("working")
            fields["step"] = .string("Jonossa")
        case .working(let step):
            fields["status"] = .string("working")
            fields["step"] = .string(step ?? "")
        case .prompt(let prompt):
            fields["status"] = .string("prompt")
            fields["prompt_id"] = .string(prompt.id)
            fields["question"] = .string(prompt.question)
            fields["options"] = .array(prompt.options.map { .string($0) })
            fields["say"] = .string(SpeechText.clean(prompt.spoken ?? prompt.question))
        case .done(let reply):
            let spoken = SpeechText.clean(reply)
            fields["status"] = .string("done")
            fields["reply"] = .string(reply)
            fields["say"] = .string(spoken.isEmpty ? "Valmis." : spoken)
        case .failed(let message):
            fields["status"] = .string("failed")
            fields["reply"] = .string(message)
            fields["say"] = .string(message)
        }
        return JSONValue.object(fields).encoded()
    }

    public static func unknownJob(_ id: String) -> Data {
        body(jobID: id, state: .failed("En löydä tätä tehtävää. Anna komento uudelleen."))
    }
}
