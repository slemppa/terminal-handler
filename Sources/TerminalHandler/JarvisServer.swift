import Foundation
import OSLog
import THCore

/// Local OpenAI-compatible endpoint for FluidVoice's Command Mode, on
/// 127.0.0.1 only. A chat request is answered at once with a short text and
/// no tool calls, so FluidVoice's turn ends cleanly; the dictated text is
/// handed to Jarvis, which does the work in the background.
///
/// The phone's routes (`/jarvis/command`, `/status`, `/answer`) come through
/// `tailscale serve`, which forwards them to this same localhost port. Their
/// answers are spoken on the phone, so Jarvis stays silent on the Mac.
nonisolated final class JarvisServer: Sendable {
    private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "jarvis-http")
    static let ackText = "Selvä, Jarvis hoitaa."

    let port: UInt16
    private let apiKey: @Sendable () -> String?
    private let remoteKey: @Sendable () -> String?
    private let remoteHosts: @Sendable () -> [String]
    private let onTranscript: @Sendable @MainActor (String) -> Void
    private let jobs: RemoteJobs
    private let onRemoteCommand: @Sendable @MainActor (String, String) -> Void
    private let onRemoteAnswer: @Sendable @MainActor (String, String) -> Void
    private let requestLog: RequestLog

    /// `onRemoteCommand(text, jobID)` queues a phone command;
    /// `onRemoteAnswer(promptID, choice)` answers what Jarvis asked.
    init(port: UInt16,
         apiKey: @escaping @Sendable () -> String?,
         remoteKey: @escaping @Sendable () -> String?,
         remoteHosts: @escaping @Sendable () -> [String],
         jobs: RemoteJobs,
         onTranscript: @escaping @Sendable @MainActor (String) -> Void,
         onRemoteCommand: @escaping @Sendable @MainActor (String, String) -> Void,
         onRemoteAnswer: @escaping @Sendable @MainActor (String, String) -> Void) {
        self.port = port
        self.apiKey = apiKey
        self.remoteKey = remoteKey
        self.remoteHosts = remoteHosts
        self.jobs = jobs
        self.onTranscript = onTranscript
        self.onRemoteCommand = onRemoteCommand
        self.onRemoteAnswer = onRemoteAnswer
        requestLog = RequestLog(url: HookPaths.supportDirectory.appending(path: "jarvis-requests.log"))
    }

    /// Returns false when the port is taken.
    @discardableResult
    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Self.log.error("could not listen on 127.0.0.1:\(self.port)")
            close(fd)
            return false
        }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    if errno == EMFILE || errno == ENFILE { Thread.sleep(forTimeInterval: 0.5) }
                    continue
                }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in
                    serve(client)
                    close(client)
                }
            }
        }
        return true
    }

    private func serve(_ fd: Int32) {
        UnixSocket.setReceiveTimeout(fd: fd, seconds: 15)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var request: HTTPRequest?
        while request == nil {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
            switch HTTPRequestParser.parse(data) {
            case .incomplete: continue
            case .complete(let r): request = r
            case .tooLarge:
                send(fd, HTTPResponse.error(status: 413, message: "Request too large")); return
            case .invalid(let why):
                requestLog.write("invalid request: \(why)")
                send(fd, HTTPResponse.error(status: 400, message: why)); return
            }
        }
        guard let request else { return }
        respond(to: request, fd: fd)
    }

    private func respond(to request: HTTPRequest, fd: Int32) {
        let route = JarvisAPI.route(request)
        let key = route.isRemote ? remoteKey() : apiKey()
        if let rejection = JarvisAPI.check(request, route: route, apiKey: key, remoteHosts: remoteHosts()) {
            requestLog.write(request, note: "rejected: \(rejection.message)")
            send(fd, HTTPResponse.error(status: rejection.status, message: rejection.message))
            return
        }
        switch route {
        case .remoteCommand, .remoteStatus, .remoteAnswer:
            respondRemote(to: request, route: route, fd: fd)
        case .notFound:
            requestLog.write(request, note: "404")
            send(fd, HTTPResponse.error(status: 404, message: "Not found"))
        case .models:
            requestLog.write(request, note: "models")
            send(fd, HTTPResponse.full(status: 200, body: JarvisAPI.modelsBody()))
        case .chatCompletions:
            guard let chat = ChatRequest.parse(request.body) else {
                requestLog.write(request, note: "bad chat body")
                send(fd, HTTPResponse.error(status: 400, message: "Expected a chat completion request"))
                return
            }
            let note = "chat stream=\(chat.stream) messages=\(chat.messageCount) tools=\(chat.toolCount) last=\(chat.lastRole) transcript=\(chat.transcript.map { "\"\($0)\"" } ?? "-")"
            requestLog.write(request, note: note)
            let id = "chatcmpl-jarvis-" + UUID().uuidString.prefix(12).lowercased()
            let created = Int(Date().timeIntervalSince1970)
            // Anything but a fresh command (e.g. a tool result) just ends the turn.
            // A provider check gets a plain OK and never starts Jarvis.
            let probe = chat.isConnectionProbe
            let text = probe ? "OK" : chat.transcript == nil ? "Valmis." : Self.ackText
            if chat.stream {
                var out = HTTPResponse.head(status: 200, headers: [
                    ("Content-Type", "text/event-stream; charset=utf-8"),
                    ("Cache-Control", "no-cache"),
                    ("Connection", "close"),
                ])
                out.append(JarvisAPI.streamEvents(id: id, model: chat.model, created: created, text: text))
                send(fd, out)
            } else {
                send(fd, HTTPResponse.full(status: 200, body: JarvisAPI.completionBody(id: id, model: chat.model, created: created, text: text)))
            }
            if !probe, let transcript = chat.transcript {
                let onTranscript = onTranscript
                let fromFluidVoice = request.header("user-agent")?.hasPrefix("FluidVoice") ?? false
                Task { @MainActor in
                    onTranscript(transcript)
                    if fromFluidVoice { FluidVoiceNotch.closeAfterReply() }
                }
            }
        }
    }

    /// Each call waits up to `RemoteAPI.waitSeconds` for something the phone
    /// must act on, then returns the job's state.
    private func respondRemote(to request: HTTPRequest, route: JarvisAPI.Route, fd: Int32) {
        let timeout = RemoteAPI.waitSeconds
        switch route {
        case .remoteCommand:
            guard let text = RemoteAPI.commandText(request.body) else {
                requestLog.write(request, note: "remote: no text")
                send(fd, HTTPResponse.error(status: 400, message: "Expected {\"text\": \"…\"}"))
                return
            }
            let id = jobs.create()
            requestLog.write(request, note: "remote command \(id)")
            let onRemoteCommand = onRemoteCommand
            Task { @MainActor in onRemoteCommand(text, id) }
            reply(fd, id: id, snapshot: jobs.wait(id, timeout: timeout))
        case .remoteStatus:
            guard let id = RemoteAPI.jobID(request.body) else {
                send(fd, HTTPResponse.error(status: 400, message: "Expected {\"id\": \"…\"}"))
                return
            }
            reply(fd, id: id, snapshot: jobs.wait(id, timeout: timeout))
        case .remoteAnswer:
            guard let answer = RemoteAPI.answer(request.body) else {
                send(fd, HTTPResponse.error(status: 400, message: "Expected {\"id\", \"prompt_id\", \"choice\"}"))
                return
            }
            requestLog.write(request, note: "remote answer \(answer.jobID)")
            let before = jobs.snapshot(answer.jobID)?.version
            let onRemoteAnswer = onRemoteAnswer
            Task { @MainActor in onRemoteAnswer(answer.promptID, answer.choice) }
            reply(fd, id: answer.jobID, snapshot: jobs.wait(answer.jobID, after: before, timeout: timeout))
        default:
            send(fd, HTTPResponse.error(status: 404, message: "Not found"))
        }
    }

    private func reply(_ fd: Int32, id: String, snapshot: RemoteJobs.Snapshot?) {
        let body = snapshot.map { RemoteAPI.body(jobID: id, state: $0.state) } ?? RemoteAPI.unknownJob(id)
        send(fd, HTTPResponse.full(status: 200, body: body))
    }

    private func send(_ fd: Int32, _ data: Data) {
        _ = UnixSocket.writeAll(fd: fd, data: data)
        shutdown(fd, SHUT_WR)
    }
}

/// Raw requests, so the exact shape FluidVoice sends can be checked.
/// Rotated at 4 MB (one previous file kept as .1).
nonisolated final class RequestLog: Sendable {
    private let url: URL
    private let lock = NSLock()
    private static let maxBytes = 4 << 20
    private static let maxBodyBytes = 256 << 10

    init(url: URL) { self.url = url }

    func write(_ request: HTTPRequest, note: String) {
        var text = "\(request.method) \(request.path)  [\(note)]\n"
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            let shown = ["authorization", "x-api-key"].contains(name) ? "<\(value.count) merkkiä, piilotettu>" : value
            text += "  \(name): \(shown)\n"
        }
        if !request.body.isEmpty {
            let body = request.body.prefix(Self.maxBodyBytes)
            text += "  body (\(request.body.count) B):\n" + String(decoding: body, as: UTF8.self) + "\n"
        }
        write(text)
    }

    func write(_ text: String) {
        let entry = "=== \(Date.now.ISO8601Format()) " + text + "\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        try? handle.close()
    }
}
