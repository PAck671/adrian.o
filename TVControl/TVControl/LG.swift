import CryptoKit
import Foundation
import Network
import Security

struct LGApp: Identifiable, Hashable {
    let id: String
    let name: String
}

struct LGInput: Identifiable, Hashable {
    let id: String
    let name: String
    let connected: Bool
}

/// Keeps the TV's pairing key and certificate fingerprint on this device only.
enum LGVault {
    private static let service = "com.adriantools.tvcontrol.lg"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, _ account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// LG TVs use a private certificate, so the first one seen is remembered and any change is refused.
final class LGPin: @unchecked Sendable {
    private let account: String
    private let lock = NSLock()
    private var rejected = false

    init(host: String) {
        account = "cert.\(host)"
    }

    var didReject: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    func accepts(_ fingerprint: String) -> Bool {
        guard let known = LGVault.read(account) else {
            LGVault.write(fingerprint, account)
            return true
        }
        guard known == fingerprint else {
            lock.lock()
            rejected = true
            lock.unlock()
            return false
        }
        return true
    }
}

enum WS {
    static func connection(to url: URL, pin: LGPin) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            complete(pin.accepts(digest.map { String(format: "%02x", $0) }.joined()))
        }, .global())
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return NWConnection(to: .url(url), using: parameters)
    }

    static func send(_ connection: NWConnection, _ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Returns the next text message, or nil for a control frame.
    static func receive(_ connection: NWConnection) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let context,
                      let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                    continuation.resume(throwing: TVError.closed)
                    return
                }
                switch metadata.opcode {
                case .text: continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                case .close: continuation.resume(throwing: TVError.closed)
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}

enum LGMessage {
    // LG's published test-app manifest, the standard way third-party remotes pair. The owner still approves on the TV.
    private static let signature = "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbm"
        + "ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR"
        + "+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy"
        + "aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4"
        + "RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n"
        + "50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM"
        + "2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj"
        + "oa7NQnAtw=="

    static func registration(clientKey: String?) -> [String: Any] {
        let signed: [String: Any] = [
            "appId": "com.lge.test",
            "created": "20140509",
            "localizedAppNames": ["": "LG Remote App", "ko-KR": "리모컨 앱", "zxx-XX": "ЛГ Rэмotэ AПП"],
            "localizedVendorNames": ["": "LG Electronics"],
            "permissions": [
                "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_LGE_SDX",
                "READ_NOTIFICATIONS", "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
                "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP",
                "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME",
            ],
            "serial": "2f930e2d2cfe083771f68e4fe7bb07",
            "vendorId": "com.lge",
        ]
        let manifest: [String: Any] = [
            "appVersion": "1.1",
            "manifestVersion": 1,
            "permissions": [
                "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
                "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK",
                "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST",
                "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO", "CONTROL_INPUT_TEXT",
                "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_SETTINGS",
            ],
            "signatures": [["signature": signature, "signatureVersion": 1]],
            "signed": signed,
        ]
        var payload: [String: Any] = ["forcePairing": false, "manifest": manifest, "pairingType": "PROMPT"]
        if let clientKey { payload["client-key"] = clientKey }
        return payload
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum LGCommands {
    static let apps = "ssap://com.webos.applicationManager/listLaunchPoints"
    static let inputs = "ssap://tv/getExternalInputList"
    static let launch = "ssap://system.launcher/launch"
    static let switchInput = "ssap://tv/switchInput"
    static let insertText = "ssap://com.webos.service.ime/insertText"
    static let turnOff = "ssap://system/turnOff"
    static let play = "ssap://media.controls/play"
    static let pause = "ssap://media.controls/pause"
    static let pointer = "ssap://com.webos.service.networkinput/getPointerInputSocket"
    // The Google TV box reports HDMI-CEC address 3.0.0.0, which is the LG's HDMI 3.
    static let googleTVInput = "HDMI_3"
    // CleanYourTV replaces this app. The TV's HOME key opens LG's separate fullhome app instead.
    static let homeApp = "com.webos.app.home"

    static func button(for code: Int) -> String? {
        typealias Key = TVCommands.Key
        switch code {
        case Key.up: return "UP"
        case Key.down: return "DOWN"
        case Key.left: return "LEFT"
        case Key.right: return "RIGHT"
        case Key.ok: return "ENTER"
        case Key.back: return "BACK"
        case Key.volumeUp: return "VOLUMEUP"
        case Key.volumeDown: return "VOLUMEDOWN"
        case Key.mute: return "MUTE"
        case Key.rewind: return "REWIND"
        case Key.forward: return "FASTFORWARD"
        default: return nil
        }
    }

    static func parseApps(_ payload: [String: Any]) -> [LGApp] {
        var seen = Set<String>()
        let points = payload["launchPoints"] as? [[String: Any]] ?? []
        return points.compactMap { point -> LGApp? in
            guard let id = point["id"] as? String, let name = point["title"] as? String, seen.insert(id).inserted else { return nil }
            return LGApp(id: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseInputs(_ payload: [String: Any]) -> [LGInput] {
        let devices = payload["devices"] as? [[String: Any]] ?? []
        return devices.compactMap { device in
            guard let id = device["id"] as? String else { return nil }
            return LGInput(id: id, name: device["label"] as? String ?? id, connected: device["connected"] as? Bool ?? false)
        }
    }

    /// The TV hands back a socket address, which must stay on the same TV and on the encrypted port.
    static func pointerURL(_ raw: String, host: String) -> URL? {
        guard var parts = URLComponents(string: raw), parts.host == host, !parts.path.isEmpty else { return nil }
        parts.scheme = "wss"
        parts.port = 3001
        return parts.url
    }
}

actor LGClient {
    private var socket: NWConnection?
    private var pointer: NWConnection?
    private var pointerOpening: Task<Void, Error>?
    private var reader: Task<Void, Never>?
    private var pin: LGPin?
    private var host = ""
    private var nextID = 1
    private var waiters: [String: CheckedContinuation<[String: Any], Error>] = [:]

    var isConnected: Bool { socket != nil }

    func connect(host newHost: String, onPrompt: @escaping @Sendable () -> Void) async throws {
        guard socket == nil, let url = URL(string: "wss://\(newHost):3001") else { return }
        let newPin = LGPin(host: newHost)
        let candidate = WS.connection(to: url, pin: newPin)
        do {
            try await Net.ready(candidate, timeout: 10)
        } catch {
            candidate.cancel()
            throw newPin.didReject ? TVError.certificateChanged : error
        }

        // Leaves time to press Accept on the TV, and unblocks the read if nobody does.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { candidate.cancel() }
        }
        defer { watchdog.cancel() }

        let account = "key.\(newHost)"
        let saved = LGVault.read(account)
        do {
            let message: [String: Any] = ["id": "register_0", "type": "register", "payload": LGMessage.registration(clientKey: saved)]
            guard let text = LGMessage.encode(message) else { throw TVError.closed }
            WS.send(candidate, text)
            register: while true {
                guard let raw = try await WS.receive(candidate), let reply = LGMessage.decode(raw),
                      reply["id"] as? String == "register_0" else { continue }
                let payload = reply["payload"] as? [String: Any]
                switch reply["type"] as? String {
                case "response":
                    if payload?["pairingType"] as? String == "PROMPT" { onPrompt() }
                case "registered":
                    if let key = payload?["client-key"] as? String { LGVault.write(key, account) }
                    break register
                case "error":
                    if saved != nil { LGVault.delete(account) }
                    throw TVError.tvRejected("The LG TV didn't allow this phone. Tap Retry, then choose Accept on the TV.")
                default:
                    break
                }
            }
        } catch {
            candidate.cancel()
            throw error
        }

        host = newHost
        pin = newPin
        socket = candidate
        reader = Task { [weak self] in
            do {
                while true {
                    if let text = try await WS.receive(candidate) { await self?.handle(text) }
                }
            } catch {
                await self?.dropped(candidate)
            }
        }
    }

    func request(_ uri: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard let socket else { throw TVError.closed }
        let id = String(nextID)
        nextID += 1
        guard let text = LGMessage.encode(["id": id, "type": "request", "uri": uri, "payload": payload]) else { throw TVError.closed }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { await self?.expire(id) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            WS.send(socket, text)
        }
    }

    func button(_ name: String) async throws {
        if pointer == nil {
            let opening = pointerOpening ?? Task { try await self.openPointer() }
            pointerOpening = opening
            defer { pointerOpening = nil }
            try await opening.value
        }
        guard let pointer else { throw TVError.closed }
        WS.send(pointer, "type:button\nname:\(name)\n\n")
    }

    func disconnect() {
        guard let current = socket else { return }
        dropped(current)
    }

    func forget(host target: String) {
        disconnect()
        LGVault.delete("key.\(target)")
        LGVault.delete("cert.\(target)")
    }

    private func openPointer() async throws {
        guard let pin else { throw TVError.closed }
        let reply = try await request(LGCommands.pointer)
        guard let raw = reply["socketPath"] as? String, let url = LGCommands.pointerURL(raw, host: host) else {
            throw TVError.tvRejected("The LG TV didn't open its remote control channel.")
        }
        let candidate = WS.connection(to: url, pin: pin)
        try await Net.ready(candidate, timeout: 8)
        candidate.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.pointerClosed(candidate) }
            default: break
            }
        }
        pointer = candidate
    }

    private func pointerClosed(_ closed: NWConnection) {
        if pointer === closed { pointer = nil }
    }

    private func handle(_ text: String) {
        guard let message = LGMessage.decode(text), let id = message["id"] as? String,
              let waiter = waiters.removeValue(forKey: id) else { return }
        if message["type"] as? String == "error" {
            waiter.resume(throwing: TVError.tvRejected(message["error"] as? String ?? "The LG TV refused that command."))
        } else {
            waiter.resume(returning: message["payload"] as? [String: Any] ?? [:])
        }
    }

    private func expire(_ id: String) {
        waiters.removeValue(forKey: id)?.resume(throwing: TVError.timedOut)
    }

    private func dropped(_ closed: NWConnection) {
        guard socket === closed else { return }
        socket = nil
        reader?.cancel()
        reader = nil
        closed.cancel()
        pointer?.cancel()
        pointer = nil
        let open = waiters
        waiters = [:]
        open.values.forEach { $0.resume(throwing: TVError.closed) }
    }
}
