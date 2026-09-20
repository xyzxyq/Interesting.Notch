import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let port: UInt16
    if arguments.isEmpty { port = 19427 }
    else if arguments.count == 2, arguments[0] == "--port", let value = UInt16(arguments[1]), value > 0 { port = value }
    else { throw BridgeError.invalid("Usage: codex-notch-bridge [--port PORT]") }
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex", isDirectory: true).standardizedFileURL
    let bridge = try Bridge(home: home)
    bridge.start()
    try serve(port: port, bridge: bridge)
} catch {
    // Never print account data, socket payloads, questions or answers.
    fputs("Codex bridge could not start. Check its arguments and local port.\n", stderr)
    exit(1)
}
