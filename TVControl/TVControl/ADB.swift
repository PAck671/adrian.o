import Foundation
import Network
import Security

enum TVError: LocalizedError {
    case closed, timedOut, noWiFi, keyFailed, prepareFailed, certificateChanged
    case castFailed(String), tvRejected(String)

    var errorDescription: String? {
        switch self {
        case .closed: "The TV connection closed."
        case .timedOut: "The TV didn't answer in time."
        case .noWiFi: "Connect your phone to the same Wi-Fi as the TV."
        case .keyFailed: "Couldn't create this phone's secure TV key."
        case .prepareFailed: "That file couldn't be prepared for the TV."
        case .certificateChanged: "The LG TV's security certificate changed. If you trust it, use Forget LG pairing in the TV tab."
        case .castFailed(let message), .tvRejected(let message): message
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

enum Net {
    static func ready(_ connection: NWConnection, timeout: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: TVError.closed) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    connection.cancel()
                    continuation.resume(throwing: TVError.timedOut)
                }
            }
        }
    }

    static func receive(_ connection: NWConnection, _ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TVError.closed)
                }
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

enum ADBKey {
    private static let tag = Data("com.adriantools.tvcontrol.adbkey".utf8)

    static func loadOrCreate() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
            return item as! SecKey
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw TVError.keyFailed }
        return key
    }

    static func sign(_ token: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        // ADB's token is already the digest, so it is signed as-is with SHA-1 PKCS#1 padding.
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) else {
            throw TVError.keyFailed
        }
        return signature as Data
    }

    static func publicPayload(for key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let encoded = androidPublicKey(pkcs1: der) else { throw TVError.keyFailed }
        return Data("\(encoded) tvcontrol@iphone\0".utf8)
    }

    /// Converts a PKCS#1 RSA public key to the base64 layout adbd expects.
    static func androidPublicKey(pkcs1 der: Data) -> String? {
        let bytes = [UInt8](der)
        var index = 1
        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index])
            index += 1
            if first < 0x80 { return first }
            let count = first & 0x7f
            guard count <= 4, index + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
            return length
        }
        func readInteger() -> [UInt8]? {
            guard index < bytes.count, bytes[index] == 0x02 else { return nil }
            index += 1
            guard let length = readLength(), index + length <= bytes.count else { return nil }
            defer { index += length }
            return Array(bytes[index..<(index + length)].drop { $0 == 0 })
        }
        guard bytes.first == 0x30, readLength() != nil,
              let modulus = readInteger(), let exponentBytes = readInteger(),
              modulus.count == 256, exponentBytes.count <= 4 else { return nil }

        var n = [UInt32](repeating: 0, count: 64)
        for (offset, byte) in modulus.reversed().enumerated() {
            n[offset / 4] |= UInt32(byte) << UInt32(8 * (offset % 4))
        }
        var inverse = n[0]
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }

        // rr = 2^4096 mod n, built by repeated doubling.
        var rr = [UInt32](repeating: 0, count: 64)
        rr[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for word in 0..<64 {
                let value = rr[word]
                rr[word] = value << 1 | carry
                carry = value >> 31
            }
            var atLeastN = carry == 1
            if !atLeastN {
                atLeastN = true
                for word in (0..<64).reversed() where rr[word] != n[word] {
                    atLeastN = rr[word] > n[word]
                    break
                }
            }
            if atLeastN {
                var borrow: UInt64 = 0
                for word in 0..<64 {
                    let difference = UInt64(rr[word]) &- UInt64(n[word]) &- borrow
                    rr[word] = UInt32(truncatingIfNeeded: difference)
                    borrow = difference >> 63
                }
            }
        }

        let exponent = exponentBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var out = Data(capacity: 524)
        for value in [UInt32(64), 0 &- inverse] + n + rr + [exponent] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out.base64EncodedString()
    }
}

struct ADBPacket {
    static let cnxn: UInt32 = 0x4e58_4e43
    static let auth: UInt32 = 0x4854_5541
    static let open: UInt32 = 0x4e45_504f
    static let okay: UInt32 = 0x5941_4b4f
    static let clse: UInt32 = 0x4553_4c43
    static let wrte: UInt32 = 0x4554_5257

    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var payload = Data()

    func encoded() -> Data {
        var data = Data(capacity: 24 + payload.count)
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for value in [command, arg0, arg1, UInt32(payload.count), checksum, ~command] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    static func read(from connection: NWConnection) async throws -> ADBPacket {
        let header = [UInt8](try await Net.receive(connection, 24))
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << UInt32(8 * $1) }
        }
        let length = Int(word(12))
        guard word(20) == ~word(0), length <= 1_048_576 else { throw TVError.closed }
        return ADBPacket(command: word(0), arg0: word(4), arg1: word(8), payload: try await Net.receive(connection, length))
    }
}

actor ADBClient {
    private struct Stream {
        var output = Data()
        let done: CheckedContinuation<String, Error>
    }

    private let key: SecKey
    private let publicKey: Data
    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var nextID: UInt32 = 1
    private var streams: [UInt32: Stream] = [:]

    init() throws {
        key = try ADBKey.loadOrCreate()
        publicKey = try ADBKey.publicPayload(for: key)
    }

    var isConnected: Bool { connection != nil }

    func connect(host: String, port: UInt16 = 5555, onApprovalNeeded: @escaping @Sendable () -> Void) async throws {
        guard connection == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let candidate = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        try await Net.ready(candidate, timeout: 20)

        // Leaves time to press Allow on the TV, and unblocks the read if nobody does.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { candidate.cancel() }
        }
        defer { watchdog.cancel() }

        do {
            Net.send(candidate, ADBPacket(command: ADBPacket.cnxn, arg0: 0x0100_0001, arg1: 256 * 1024,
                                          payload: Data("host::\0".utf8)).encoded())
            var signed = false, offered = false
            while true {
                let packet = try await ADBPacket.read(from: candidate)
                if packet.command == ADBPacket.cnxn { break }
                guard packet.command == ADBPacket.auth, packet.arg0 == 1 else { continue }
                if !signed {
                    signed = true
                    let signature = try ADBKey.sign(packet.payload, with: key)
                    Net.send(candidate, ADBPacket(command: ADBPacket.auth, arg0: 2, arg1: 0, payload: signature).encoded())
                } else if !offered {
                    offered = true
                    Net.send(candidate, ADBPacket(command: ADBPacket.auth, arg0: 3, arg1: 0, payload: publicKey).encoded())
                    onApprovalNeeded()
                }
            }
        } catch {
            candidate.cancel()
            throw error
        }

        connection = candidate
        reader = Task { [weak self] in
            do {
                while true {
                    let packet = try await ADBPacket.read(from: candidate)
                    await self?.handle(packet)
                }
            } catch {
                await self?.dropped(candidate)
            }
        }
    }

    func shell(_ command: String, timeout: Double = 15) async throws -> String {
        guard let connection else { throw TVError.closed }
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { await self?.expire(id) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            streams[id] = Stream(done: continuation)
            Net.send(connection, ADBPacket(command: ADBPacket.open, arg0: id, arg1: 0,
                                           payload: Data("shell:\(command)\0".utf8)).encoded())
        }
    }

    func reboot() {
        guard let connection else { return }
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        Net.send(connection, ADBPacket(command: ADBPacket.open, arg0: id, arg1: 0, payload: Data("reboot:\0".utf8)).encoded())
    }

    func disconnect() {
        guard let current = connection else { return }
        dropped(current)
    }

    private func handle(_ packet: ADBPacket) {
        guard let connection else { return }
        switch packet.command {
        case ADBPacket.wrte:
            guard streams[packet.arg1] != nil else { return }
            streams[packet.arg1]?.output.append(packet.payload)
            Net.send(connection, ADBPacket(command: ADBPacket.okay, arg0: packet.arg1, arg1: packet.arg0).encoded())
        case ADBPacket.clse:
            guard let stream = streams.removeValue(forKey: packet.arg1) else { return }
            Net.send(connection, ADBPacket(command: ADBPacket.clse, arg0: packet.arg1, arg1: packet.arg0).encoded())
            stream.done.resume(returning: String(decoding: stream.output, as: UTF8.self))
        default:
            break
        }
    }

    private func expire(_ id: UInt32) {
        streams.removeValue(forKey: id)?.done.resume(throwing: TVError.timedOut)
    }

    private func dropped(_ closed: NWConnection) {
        guard connection === closed else { return }
        connection = nil
        reader?.cancel()
        reader = nil
        closed.cancel()
        let open = streams
        streams = [:]
        open.values.forEach { $0.done.resume(throwing: TVError.closed) }
    }
}
