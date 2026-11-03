import Foundation
import os
import zlib

/// A dispatch from the gateway: event name plus its raw JSON (`d` decoded lazily).
nonisolated struct GatewayDispatch: Sendable {
    var name: String
    var data: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(Envelope<T>.self, from: data).d
    }

    private struct Envelope<T: Decodable>: Decodable { var d: T }
}

nonisolated enum GatewayStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case resuming
    case waiting(retryIn: Int)
    case failed(String)
}

nonisolated enum GatewayEvent: Sendable {
    case status(GatewayStatus)
    case dispatch(GatewayDispatch)
}

/// What the app needs from a gateway connection; live and mock conform.
nonisolated protocol GatewayConnection: AnyObject, Sendable {
    var events: AsyncStream<GatewayEvent> { get }
    func connect() async
    func disconnect() async
    /// Op 14: subscribe to a guild's typing, activities and member list ranges.
    func subscribe(guild: Snowflake, channel: Snowflake?, ranges: [[Int]]) async
    /// Op 8: members whose username or nickname starts with `query`
    /// (answered by GUILD_MEMBERS_CHUNK), as the web client's autocomplete asks.
    func requestMembers(guild: Snowflake, query: String, limit: Int) async
}

/// Inflates Discord's zlib-stream transport compression: one zlib stream
/// for the life of the connection, each message ending in 00 00 FF FF.
nonisolated final class ZlibStreamInflater {
    private var stream = z_stream()
    private var buffer = Data()
    private var ready = false

    init() {
        ready = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }

    deinit { if ready { inflateEnd(&stream) } }

    /// Appends a frame; returns a complete JSON message once the suffix arrives.
    func push(_ data: Data) -> Data? {
        buffer.append(data)
        guard buffer.count >= 4, buffer.suffix(4) == Data([0x00, 0x00, 0xFF, 0xFF]) else { return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        var output = Data()
        let chunk = 64 * 1024
        var scratch = [UInt8](repeating: 0, count: chunk)
        let ok: Bool = buffer.withUnsafeMutableBytes { (input: UnsafeMutableRawBufferPointer) -> Bool in
            stream.next_in = input.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(input.count)
            repeat {
                let status: Int32 = scratch.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_SYNC_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { return false }
                output.append(scratch, count: chunk - Int(stream.avail_out))
                if status == Z_BUF_ERROR { break }
            } while stream.avail_in > 0 || stream.avail_out == 0
            return true
        }
        return ok ? output : nil
    }
}

/// Discord gateway v10 for a user session: identify with the web client's
/// properties, heartbeat with jitter, resume after drops, re-identify when
/// the session is invalid, back off between attempts.
final class LiveGateway: GatewayConnection, @unchecked Sendable {
    let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    private let credentials: SessionCredentials
    private let queue = DispatchQueue(label: "duocord.gateway")
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "gateway")

    // Guarded by `queue`.
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var inflater = ZlibStreamInflater()
    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: String?
    private var heartbeatTimer: DispatchSourceTimer?
    private var awaitingAck = false
    private var attempts = 0
    private var stopped = true
    private var generation = 0

    /// Bit flags the web client sends; chosen so READY carries classic full
    /// guild objects (no client-state v2) with versioned read states,
    /// deduplicated users and protobuf settings.
    static let capabilities = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 9)

    init(credentials: SessionCredentials) {
        self.credentials = credentials
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func connect() async {
        queue.async { [self] in
            stopped = false
            open(resume: false)
        }
    }

    func disconnect() async {
        queue.async { [self] in
            stopped = true
            teardown(code: .normalClosure)
            sessionID = nil
            sequence = nil
            continuation.yield(.status(.disconnected))
        }
    }

    func subscribe(guild: Snowflake, channel: Snowflake?, ranges: [[Int]]) async {
        var payload: [String: JSONValue] = [
            "guild_id": .string(guild.description),
            "typing": .bool(true),
            "activities": .bool(true),
            "threads": .bool(true),
        ]
        if let channel {
            payload["channels"] = .object([channel.description: .array(ranges.map { .array($0.map { .number(Double($0)) }) })])
        }
        queue.async { [self] in send(op: 14, data: .object(payload)) }
    }

    func requestMembers(guild: Snowflake, query: String, limit: Int) async {
        let payload: JSONValue = .object([
            "guild_id": .array([.string(guild.description)]),
            "query": .string(query),
            "limit": .number(Double(limit)),
        ])
        queue.async { [self] in send(op: 8, data: payload) }
    }

    // MARK: Connection (on queue)

    private func open(resume: Bool) {
        teardown(code: .goingAway)
        generation += 1
        let current = generation
        inflater = ZlibStreamInflater()
        let host = (resume ? resumeURL : nil) ?? "wss://gateway.discord.gg"
        var components = URLComponents(string: host)!
        components.queryItems = [URLQueryItem(name: "encoding", value: "json"),
                                 URLQueryItem(name: "v", value: "10"),
                                 URLQueryItem(name: "compress", value: "zlib-stream")]
        var request = URLRequest(url: components.url!)
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.urlSession = session
        self.task = task
        continuation.yield(.status(resume ? .resuming : .connecting))
        task.resume()
        receive(task, generation: current, resume: resume)
    }

    private func teardown(code: URLSessionWebSocketTask.CloseCode) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        task?.cancel(with: code, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        awaitingAck = false
    }

    private func receive(_ task: URLSessionWebSocketTask, generation current: Int, resume: Bool) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation else { return }
                switch result {
                case .success(let message):
                    let frame: Data
                    switch message {
                    case .data(let data): frame = data
                    case .string(let string): frame = Data(string.utf8)
                    @unknown default: frame = Data()
                    }
                    if let json = (frame.first == UInt8(ascii: "{")) ? frame : self.inflater.push(frame) {
                        self.handle(json, resume: resume)
                    }
                    self.receive(task, generation: current, resume: resume)
                case .failure(let error):
                    let code = task.closeCode.rawValue
                    self.log.notice("gateway closed \(code) \(error.localizedDescription, privacy: .public)")
                    self.closed(code: code)
                }
            }
        }
    }

    private struct Header: Decodable {
        var op: Int
        var s: Int?
        var t: String?
    }

    private func handle(_ json: Data, resume: Bool) {
        guard let header = try? JSONDecoder().decode(Header.self, from: json) else { return }
        if let s = header.s { sequence = s }
        switch header.op {
        case 10: // Hello
            struct Hello: Decodable { var heartbeat_interval: Double }
            let interval = (try? GatewayDispatch(name: "", data: json).decode(Hello.self))?.heartbeat_interval ?? 41_250
            startHeartbeat(interval: interval)
            if resume, let sessionID, let sequence {
                send(op: 6, data: .object(["token": .string(credentials.token), "session_id": .string(sessionID),
                                           "seq": .number(Double(sequence))]))
            } else {
                identify()
            }
        case 11:
            awaitingAck = false
        case 1:
            sendHeartbeat()
        case 7: // Reconnect
            open(resume: true)
        case 9: // Invalid session; d says whether it is resumable
            struct Invalid: Decodable { var d: Bool? }
            let resumable = (try? JSONDecoder().decode(Invalid.self, from: json))?.d ?? false
            if !resumable { sessionID = nil; sequence = nil }
            let delay = Double.random(in: 1...5)
            let scheduled = generation
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard !stopped, scheduled == generation else { return }
                open(resume: resumable)
            }
        case 0:
            guard let name = header.t else { return }
            if name == "READY" {
                struct Ready: Decodable { var session_id: String; var resume_gateway_url: String? }
                if let ready = try? GatewayDispatch(name: name, data: json).decode(Ready.self) {
                    sessionID = ready.session_id
                    resumeURL = ready.resume_gateway_url
                }
                attempts = 0
                continuation.yield(.status(.connected))
            } else if name == "RESUMED" {
                attempts = 0
                continuation.yield(.status(.connected))
            }
            continuation.yield(.dispatch(GatewayDispatch(name: name, data: json)))
        default:
            break
        }
    }

    private func identify() {
        var properties = credentials.properties
        // The gateway carries no referrer fields the REST header has.
        properties["is_fast_connect"] = .bool(false)
        let payload: [String: JSONValue] = [
            "token": .string(credentials.token),
            "capabilities": .number(Double(Self.capabilities)),
            "properties": .object(properties),
            "presence": .object(["status": .string("unknown"), "since": .number(0), "activities": .array([]),
                                 "afk": .bool(false)]),
            "compress": .bool(false),
            "client_state": .object(["guild_versions": .object([:])]),
        ]
        send(op: 2, data: .object(payload))
    }

    private func startHeartbeat(interval: Double) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let jitter = Double.random(in: 0...1)
        timer.schedule(deadline: .now() + .milliseconds(Int(interval * jitter)), repeating: .milliseconds(Int(interval)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.awaitingAck {
                // Zombie connection: no ack since the last beat.
                self.log.notice("heartbeat not acknowledged; reconnecting")
                self.open(resume: true)
                return
            }
            self.sendHeartbeat()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func sendHeartbeat() {
        awaitingAck = true
        send(op: 1, data: sequence.map { .number(Double($0)) } ?? .null)
    }

    private func send(op: Int, data: JSONValue) {
        guard let task else { return }
        let payload: [String: JSONValue] = ["op": .number(Double(op)), "d": data]
        guard let json = try? JSONEncoder().encode(payload), let text = String(data: json, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.log.notice("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func closed(code: Int) {
        teardown(code: .goingAway)
        guard !stopped else { return }
        // 4004 bad token, 4010-4014 config errors: don't retry.
        if code == 4004 {
            stopped = true
            continuation.yield(.status(.failed("unauthorized")))
            return
        }
        if [4010, 4011, 4012, 4013, 4014].contains(code) {
            stopped = true
            continuation.yield(.status(.failed("gateway refused the connection (\(code))")))
            return
        }
        let canResume = sessionID != nil && ![4007, 4009].contains(code)
        if !canResume { sessionID = nil; sequence = nil }
        attempts += 1
        let delay = min(30, Int(pow(2, Double(min(attempts, 5)))) / 2 + Int.random(in: 0...1))
        continuation.yield(.status(.waiting(retryIn: delay)))
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [self] in
            // A nudge may already have reconnected; never replace a newer socket.
            guard !stopped, scheduled == generation else { return }
            open(resume: canResume)
        }
    }

    /// Network came back or the app returned to the foreground: retry now.
    func nudge() {
        queue.async { [self] in
            guard !stopped, task == nil || task?.state != .running else { return }
            attempts = 0
            open(resume: sessionID != nil)
        }
    }
}
