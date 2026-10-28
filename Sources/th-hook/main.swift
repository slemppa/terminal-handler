import Foundation
import THCore

// Claude Code hook helper. Forwards the hook payload to Terminal Handler and,
// for blocking events, prints the app's answer. Any failure exits 0 with no
// output so Claude carries on exactly as if the app were not installed.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = JSONValue.parse(input) else { exit(0) }

let owner = controllingTTY(startingAt: getppid())
let envelope = HookEnvelope(tty: owner?.tty, claudePID: owner?.pid, payload: payload)
let blocking = isBlockingEvent(payload)

if let reply = HookClient.send(envelope, socketPath: HookPaths.socketPath, waitForReply: blocking),
   !reply.isEmpty {
    FileHandle.standardOutput.write(reply)
}
exit(0)
