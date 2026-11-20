import Foundation
import THCore

// Claude Code hook helper. Forwards the hook payload to Terminal Handler and,
// for blocking events, prints the app's answer. Any failure exits 0 with no
// output so Claude carries on exactly as if the app were not installed.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = JSONValue.parse(input) else { exit(0) }

let environment = ProcessInfo.processInfo.environment
let owner = environment["TH_JARVIS"] == "1" ? nil : controllingTTY(startingAt: getppid())
let envelope = HookEnvelope.make(payload: payload, environment: environment, owner: owner)
let blocking = isBlockingEvent(payload)

if let reply = HookClient.send(envelope, socketPath: HookPaths.socketPath, waitForReply: blocking),
   !reply.isEmpty {
    FileHandle.standardOutput.write(reply)
}
exit(0)
