import Foundation
import Darwin
import SQLite3

let maxFrame = 256 * 1024 * 1024
func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

final class Socket {
    let fd: Int32
    init(_ fd: Int32) throws {
        guard fd >= 0 else { throw BridgeError.disconnected }
        self.fd = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    deinit { Darwin.close(fd) }
    func ready(_ events: Int16, until deadline: Double) throws {
        while true {
            let remaining = deadline - monotonic()
            guard remaining > 0 else { throw BridgeError.timeout }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&p, 1, Int32(min(Double(Int32.max), ceil(remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { throw BridgeError.timeout }
            guard result > 0, p.revents & events != 0 else { throw BridgeError.disconnected }
            return
        }
    }
    func read(until deadline: Double, maximum: Int = 65536) throws -> Data {
        while true {
            try ready(Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: maximum)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw BridgeError.disconnected }
            return Data(bytes.prefix(count))
        }
    }
    func write(_ data: Data, until deadline: Double) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try ready(Int16(POLLOUT), until: deadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw BridgeError.disconnected }
                offset += count
            }
        }
    }
    func send(_ message: Object, until deadline: Double = monotonic() + 20) throws {
        let body = try json(message)
        guard body.count <= maxFrame else { throw BridgeError.invalid("Frame too large") }
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        try write(frame, until: deadline)
    }
    static func unix(_ path: String) throws -> Socket {
        let sock = try Socket(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.invalid("Socket path too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw BridgeError.disconnected }
            try sock.ready(Int16(POLLOUT), until: monotonic() + 20)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(sock.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw BridgeError.disconnected }
        }
        return sock
    }
}

struct Frames {
    private var buffer = Data()
    private var offset = 0
    mutating func append(_ data: Data) throws -> [Object] {
        buffer.append(data)
        var messages: [Object] = []
        while buffer.count - offset >= 4 {
            let size = Int(buffer.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
            guard size > 0, size <= maxFrame else { throw BridgeError.invalid("Invalid IPC frame") }
            guard buffer.count - offset >= size + 4 else { break }
            guard let message = try JSONSerialization.jsonObject(with: buffer.subdata(in: (offset + 4)..<(offset + 4 + size))) as? Object else { throw BridgeError.invalid("Invalid IPC message") }
            messages.append(message)
            offset += size + 4
        }
        // Compact once per receive, not once per message in a burst.
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)); offset = 0 }
        return messages
    }
}

func recentIDs(home: URL) throws -> [String] {
    var db: OpaquePointer?, query: OpaquePointer?
    guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let db { sqlite3_close(db) }; throw BridgeError.invalid("Task database unavailable")
    }
    defer { sqlite3_finalize(query); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, "SELECT id FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 100", -1, &query, nil) == SQLITE_OK else { throw BridgeError.invalid("Task query unavailable") }
    var result: [String] = []
    while sqlite3_step(query) == SQLITE_ROW {
        if let id = sqlite3_column_text(query, 0) { result.append(String(cString: id)) }
    }
    return result
}

func ipcRequest(home: URL, method: String, version: Int, params: Object, owner: String, host: String) throws -> Object {
    let socket = try Socket.unix(home.appendingPathComponent("ipc/ipc.sock").path)
    let deadline = monotonic() + 20
    var frames = Frames()
    try socket.send(["type": "request", "requestId": "reply-init", "method": "initialize", "version": 0,
                     "params": ["clientType": "interesting-notch-reply"]], until: deadline)
    let requestID = UUID().uuidString.lowercased()
    while true {
        for message in try frames.append(socket.read(until: deadline)) {
            if text(message["requestId"]) == "reply-init" {
                guard text(message["resultType"]) == "success" else { throw BridgeError.disconnected }
                var request: Object = ["type": "request", "requestId": requestID, "method": method,
                                       "version": version + (host == "local" ? 0 : 1), "params": params,
                                       "targetClientId": owner, "timeoutMs": 18000]
                if host != "local" { request["hostId"] = host }
                try socket.send(request, until: deadline)
            } else if text(message["type"]) == "response", text(message["requestId"]) == requestID { return message }
        }
    }
}

func codexBinary(environment: [String: String], applications: String = "/Applications") -> String? {
    // Current desktop bundles nest the CLI in CodexCLI.app; retain older layouts.
    let bundled = ["ChatGPT", "Codex"].flatMap { app in
        ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex"].map {
            "\(applications)/\(app).app/Contents/Resources/\($0)"
        }
    }
    let candidates = environment["CODEX_BRIDGE_CODEX_PATH"].map { [$0] } ?? (bundled
        + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
    )
    return candidates.first { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

func readFuel(home: URL) -> (Object?, [Object]) {
    guard let binary = codexBinary(environment: ProcessInfo.processInfo.environment) else { return (nil, []) }
    let process = Process(), input = Pipe(), output = Pipe(), exited = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["app-server"]
    process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": home.path]) { _, new in new }
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return (nil, []) }
    // The old implementation also used a short-lived app-server. Keep that lifetime:
    // an always-resident extra Codex process can cost more memory than it saves in CPU.
    defer {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 3)
        }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
    }
    do {
        func send(_ value: Object) throws {
            var data = try json(value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "interesting_notch", "version": "1.0"]]])
        let deadline = monotonic() + 20, fd = output.fileHandleForReading.fileDescriptor
        var buffer = Data()
        while monotonic() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let status = poll(&descriptor, 1, Int32(max(1, (deadline - monotonic()) * 1000)))
            if status < 0 && errno == EINTR { continue }
            guard status > 0, descriptor.revents & Int16(POLLIN) != 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 2_000_000 else { break }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer = Data(buffer[buffer.index(after: newline)...])
                let message = object(try JSONSerialization.jsonObject(with: line))
                if number(message["id"]) == 1 {
                    guard message["error"] == nil else { return (nil, []) }
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if number(message["id"]) == 2 {
                    let result = object(message["result"]), now = Date().timeIntervalSince1970
                    let main = Projection.fuel(result, now: now), week = Projection.fuel(result, now: now, weekly: true)
                    var windows: [Int: Object] = [:]
                    for value in [main, week].compactMap({ $0 }) { windows[Int(number(value["windowMinutes"])!)] = value }
                    return (main, windows.keys.sorted().compactMap { windows[$0] })
                }
            }
        }
    } catch { /* Never log IPC payloads or account data. */ }
    return (nil, [])
}

func serve(port: UInt16, bridge: Bridge) throws {
    let listener = try Socket(Darwin.socket(AF_INET, SOCK_STREAM, 0))
    var yes: Int32 = 1
    setsockopt(listener.fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener.fd, 16) == 0 else { throw BridgeError.invalid("Loopback port unavailable") }
    _ = fcntl(listener.fd, F_SETFL, 0) // accept blocks until work arrives; no polling timer.
    let slots = DispatchSemaphore(value: 16)
    while true {
        let fd = accept(listener.fd, nil, nil)
        if fd < 0 && errno == EINTR { continue }
        guard fd >= 0 else { throw BridgeError.disconnected }
        guard slots.wait(timeout: .now()) == .success else { Darwin.close(fd); continue }
        DispatchQueue.global(qos: .utility).async {
            defer { slots.signal() }
            autoreleasepool {
                guard let socket = try? Socket(fd) else { return }
                try? handleHTTP(socket, port: port, bridge: bridge)
            }
        }
    }
}

func handleHTTP(_ socket: Socket, port: UInt16, bridge: Bridge) throws {
    let deadline = monotonic() + 5
    var buffer = Data(), headerEnd: Range<Data.Index>?
    while headerEnd == nil {
        buffer.append(try socket.read(until: deadline, maximum: 16384))
        headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        guard (headerEnd?.upperBound ?? buffer.count) <= 16384 else { throw BridgeError.invalid("Headers too large") }
    }
    let split = headerEnd!
    guard let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { throw BridgeError.invalid("Invalid headers") }
    let lines = header.components(separatedBy: "\r\n"), request = lines[0].split(separator: " ")
    guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else { throw BridgeError.invalid("Invalid request") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw BridgeError.invalid("Invalid header") }
        let key = line[..<colon].lowercased()
        guard headers[key] == nil else { throw BridgeError.invalid("Duplicate header") }
        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    func respond(_ status: Int, _ value: Object) throws {
        let body = try json(value)
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try socket.write(Data(response.utf8) + body, until: monotonic() + 5)
    }
    guard headers["origin"] == nil, headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil else { try respond(403, [:]); return }
    if request[0] == "GET" {
        guard request[1] == "/state" else { try respond(404, [:]); return }
        try respond(200, bridge.snapshot()); return
    }
    guard request[0] == "POST", request[1] == "/answer", bridge.validToken(headers["x-notch-token"]) else { try respond(403, [:]); return }
    guard let raw = headers["content-length"], let length = Int(raw), length > 0, length <= 32768 else { try respond(409, ["error": "Invalid request size"]); return }
    var body = Data(buffer[split.upperBound...])
    guard body.count <= length else { try respond(409, ["error": "Invalid request size"]); return }
    do {
        while body.count < length { body.append(try socket.read(until: deadline, maximum: length - body.count)) }
        guard let data = try JSONSerialization.jsonObject(with: body) as? Object else { throw BridgeError.invalid("Invalid answer request") }
        try respond(200, bridge.answer(data))
    } catch BridgeError.invalid(let message) { try respond(409, ["error": message]) }
    catch { try respond(409, ["error": "提交结果暂未确认，请等待 Codex 同步，勿重复提交。"] ) }
}
