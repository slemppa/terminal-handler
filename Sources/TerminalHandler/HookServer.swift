import Foundation
import OSLog
import Synchronization
import THCore

/// One `th-hook` connection. Replied to at most once; closing it with no
/// bytes tells the hook to fall back to Claude's own prompt.
nonisolated final class HookConnection: Sendable {
    private let fd: Int32
    private let open = Mutex(true)

    init(fd: Int32) { self.fd = fd }

    func reply(_ data: Data = Data()) {
        let shouldWrite = open.withLock { isOpen in
            defer { isOpen = false }
            return isOpen
        }
        guard shouldWrite else { return }
        if !data.isEmpty { UnixSocket.writeAll(fd: fd, data: data) }
        close(fd)
    }

    /// Tells the hook to keep waiting for the real answer.
    func acknowledgeHold() {
        open.withLock { isOpen in
            guard isOpen else { return }
            var line = HookClient.holdAck
            line.append(0x0A)
            UnixSocket.writeAll(fd: fd, data: line)
        }
    }

    /// True when the hook process has gone away (Claude cancelled it).
    var peerClosed: Bool {
        open.withLock { isOpen in
            guard isOpen else { return true }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return false }
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
        }
    }
}

/// Accepts hook connections on a background thread and hands each decoded
/// envelope to the main actor.
nonisolated final class HookServer: Sendable {
    private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "server")
    private let path: String
    private let handler: @Sendable @MainActor (HookEnvelope, HookConnection) -> Void

    init(path: String = HookPaths.socketPath, handler: @escaping @Sendable @MainActor (HookEnvelope, HookConnection) -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() {
        try? FileManager.default.createDirectory(at: HookPaths.supportDirectory, withIntermediateDirectories: true)
        guard let listener = UnixSocket.listen(path: path) else {
            Self.log.error("could not listen on \(self.path, privacy: .public)")
            return
        }
        let handler = handler
        Thread.detachNewThread {
            while let client = UnixSocket.accept(fd: listener) {
                Thread.detachNewThread {
                    guard let line = UnixSocket.readLine(fd: client),
                          let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
                        close(client)
                        return
                    }
                    let connection = HookConnection(fd: client)
                    Task { @MainActor in handler(envelope, connection) }
                }
            }
        }
    }

    func stop() {
        unlink(path)
    }
}
