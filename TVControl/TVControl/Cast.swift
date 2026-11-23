import Foundation
import Network

/// One Google Cast protocol message: a length prefix around a small protobuf.
struct CastFrame {
    let source: String
    let namespace: String
    let payload: String

    static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var body = Data([0x08, 0x00])
        func field(_ tag: UInt8, _ text: String) {
            let bytes = Data(text.utf8)
            body.append(tag)
            var length = bytes.count
            while length >= 0x80 {
                body.append(UInt8(length & 0x7f) | 0x80)
                length >>= 7
            }
            body.append(UInt8(length))
            body.append(bytes)
        }
        field(0x12, source)
        field(0x1a, destination)
        field(0x22, namespace)
        body.append(contentsOf: [0x28, 0x00])
        field(0x32, payload)

        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    static func decode(_ data: Data) -> CastFrame? {
        let bytes = [UInt8](data)
        var index = 0
        var source = "", namespace = "", payload = ""
        func varint() -> Int? {
            var value = 0, shift = 0
            while index < bytes.count, shift < 35 {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), index + length <= bytes.count else { return nil }
                let text = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
                index += length
                switch key >> 3 {
                case 2: source = text
                case 4: namespace = text
                case 6: payload = text
                default: break
                }
            default:
                return nil
            }
        }
        return CastFrame(source: source, namespace: namespace, payload: payload)
    }
}

actor CastClient {
    static let mediaReceiver = "CC1AD845"
    private static let connectionNS = "urn:x-cast:com.google.cast.tp.connection"
    private static let heartbeatNS = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let receiverNS = "urn:x-cast:com.google.cast.receiver"
    private static let mediaNS = "urn:x-cast:com.google.cast.media"
    private let sender = "sender-tvcontrol"

    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var launchWaiter: CheckedContinuation<Void, Error>?
    private var requestID = 0
    private var transportID: String?
    private var appSessionID: String?
    private var mediaSessionID: Int?
    private var position = 0.0
    private var positionAt = Date()
    private var playing = false
    private var statusHandler: (@Sendable (String) -> Void)?

    func onStatus(_ handler: @escaping @Sendable (String) -> Void) {
        statusHandler = handler
    }

    func load(host: String, url: String, contentType: String, title: String) async throws {
        try await connect(host: host)
        mediaSessionID = nil
        try await launchReceiver()
        guard let transportID else { throw TVError.castFailed("The TV didn't open its media player.") }
        send(Self.connectionNS, to: transportID, ["type": "CONNECT"])
        let media: [String: Any] = [
            "contentId": url,
            "contentType": contentType,
            "streamType": "BUFFERED",
            "metadata": ["metadataType": 0, "title": title],
        ]
        send(Self.mediaNS, to: transportID, ["type": "LOAD", "requestId": nextRequest(), "media": media, "autoplay": true, "currentTime": 0])
    }

    func play() { mediaCommand("PLAY") }
    func pause() { mediaCommand("PAUSE") }

    func seek(by delta: Double) {
        let current = position + (playing ? Date().timeIntervalSince(positionAt) : 0)
        mediaCommand("SEEK", ["currentTime": max(0, current + delta)])
    }

    func setVolume(_ level: Double) {
        send(Self.receiverNS, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level))], "requestId": nextRequest()])
    }

    func stop() {
        if let appSessionID {
            send(Self.receiverNS, to: "receiver-0", ["type": "STOP", "sessionId": appSessionID, "requestId": nextRequest()])
        }
        transportID = nil
        appSessionID = nil
        mediaSessionID = nil
        playing = false
    }

    private func connect(host: String) async throws {
        guard connection == nil else { return }
        let tls = NWProtocolTLS.Options()
        // Cast receivers present a device certificate that doesn't chain to a public root.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let candidate = NWConnection(host: NWEndpoint.Host(host), port: 8009, using: NWParameters(tls: tls, tcp: .init()))
        try await Net.ready(candidate, timeout: 10)
        connection = candidate
        send(Self.connectionNS, to: "receiver-0", ["type": "CONNECT"])

        reader = Task { [weak self] in
            do {
                while true {
                    let header = [UInt8](try await Net.receive(candidate, 4))
                    let length = header.reduce(0) { $0 << 8 | Int($1) }
                    guard length <= 1_048_576 else { throw TVError.closed }
                    let body = try await Net.receive(candidate, length)
                    if let frame = CastFrame.decode(body) { await self?.handle(frame) }
                }
            } catch {
                await self?.dropped(candidate)
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.ping()
            }
        }
    }

    private func launchReceiver() async throws {
        transportID = nil
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { await self?.failLaunch("The TV didn't open its media player.") }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            launchWaiter = continuation
            send(Self.receiverNS, to: "receiver-0", ["type": "LAUNCH", "appId": Self.mediaReceiver, "requestId": nextRequest()])
        }
    }

    private func handle(_ frame: CastFrame) {
        guard let data = frame.payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "PING":
            send(Self.heartbeatNS, to: frame.source, ["type": "PONG"])
        case "RECEIVER_STATUS":
            let status = json["status"] as? [String: Any]
            let apps = status?["applications"] as? [[String: Any]] ?? []
            if let app = apps.first(where: { $0["appId"] as? String == Self.mediaReceiver }),
               let transport = app["transportId"] as? String {
                transportID = transport
                appSessionID = app["sessionId"] as? String
                launchWaiter?.resume()
                launchWaiter = nil
            }
        case "MEDIA_STATUS":
            guard let status = (json["status"] as? [[String: Any]])?.first else { return }
            mediaSessionID = status["mediaSessionId"] as? Int ?? mediaSessionID
            if let time = status["currentTime"] as? Double {
                position = time
                positionAt = Date()
            }
            if let state = status["playerState"] as? String {
                playing = state == "PLAYING"
                switch state {
                case "PLAYING": statusHandler?("Playing")
                case "PAUSED": statusHandler?("Paused")
                case "BUFFERING": statusHandler?("Buffering")
                case "IDLE":
                    let reason = status["idleReason"] as? String
                    if reason == "ERROR" { statusHandler?("The TV couldn't play this") }
                    if reason == "FINISHED" { statusHandler?("Finished") }
                default: break
                }
            }
        case "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST":
            statusHandler?("The TV couldn't play this")
        case "LAUNCH_ERROR":
            failLaunch("The TV couldn't open its media player.")
        default:
            break
        }
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) {
        guard let transportID, let mediaSessionID else { return }
        var body = extra
        body["type"] = type
        body["mediaSessionId"] = mediaSessionID
        body["requestId"] = nextRequest()
        send(Self.mediaNS, to: transportID, body)
    }

    private func send(_ namespace: String, to destination: String, _ body: [String: Any]) {
        guard let connection, let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        Net.send(connection, CastFrame.encode(source: sender, destination: destination, namespace: namespace,
                                              payload: String(decoding: json, as: UTF8.self)))
    }

    private func nextRequest() -> Int {
        requestID += 1
        return requestID
    }

    private func ping() {
        send(Self.heartbeatNS, to: "receiver-0", ["type": "PING"])
    }

    private func failLaunch(_ message: String) {
        launchWaiter?.resume(throwing: TVError.castFailed(message))
        launchWaiter = nil
    }

    private func dropped(_ closed: NWConnection) {
        guard connection === closed else { return }
        connection = nil
        reader?.cancel()
        heartbeat?.cancel()
        closed.cancel()
        transportID = nil
        appSessionID = nil
        mediaSessionID = nil
        playing = false
        failLaunch("The Cast connection closed.")
    }
}

/// Serves the one picked file to the TV over Wi-Fi, with byte ranges so video can seek.
final class MediaServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tvcontrol.media")
    private var listener: NWListener?
    private var file: URL?
    private var contentType = ""
    private var token = ""

    func publish(_ url: URL, contentType: String) async throws -> URL {
        guard let address = Self.wifiAddress() else { throw TVError.noWiFi }
        let port = try await startIfNeeded()
        let newToken = UUID().uuidString
        queue.sync {
            file = url
            self.contentType = contentType
            token = newToken
        }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = address
        parts.port = Int(port)
        parts.path = "/\(newToken)/media.\(url.pathExtension)"
        guard let served = parts.url else { throw TVError.prepareFailed }
        return served
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            file = nil
            token = ""
        }
    }

    private func startIfNeeded() async throws -> UInt16 {
        if let port = queue.sync(execute: { listener?.port?.rawValue }) { return port }
        let created = try NWListener(using: .tcp)
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            created.stateUpdateHandler = { [weak self, weak created] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                    if self?.listener === created { self?.listener = nil }
                case .cancelled:
                    once.run { continuation.resume(throwing: TVError.closed) }
                    if self?.listener === created { self?.listener = nil }
                default:
                    break
                }
            }
            created.start(queue: queue)
        }
        queue.sync { listener = created }
        guard let port = created.port?.rawValue else { throw TVError.closed }
        return port
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            if let end = next.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: next[next.startIndex..<end.lowerBound], as: UTF8.self))
            } else if isComplete || next.count > 16_384 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: next)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD", !token.isEmpty,
              request[1].hasPrefix("/\(token)/"), let file,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        var start = 0, end = size - 1, partial = false
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let range = Self.parseRange(String(line.dropFirst(6)), size: size) {
            (start, end) = range
            partial = true
        }
        let length = end - start + 1
        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        header += "Content-Type: \(contentType)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"

        let isHead = request[0] == "HEAD"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, !isHead, (try? handle.seek(toOffset: UInt64(start))) != nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.pump(connection, handle, remaining: length)
        })
    }

    private func pump(_ connection: NWConnection, _ handle: FileHandle, remaining: Int) {
        guard remaining > 0, let chunk = try? handle.read(upToCount: min(remaining, 256 * 1024)), !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                connection.cancel()
            } else {
                self?.pump(connection, handle, remaining: remaining - chunk.count)
            }
        })
    }

    static func parseRange(_ text: String, size: Int) -> (Int, Int)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = Int(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(Int(parts[1]) ?? size - 1, size - 1)
        return end >= start ? (start, end) : nil
    }

    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
