import AVFoundation
import Network
import SwiftUI

struct HubApp: Identifiable, Hashable {
    let id: String
    let name: String
}

struct HubScreen: Identifiable {
    let id: String
    let name: String
    let online: Bool
    let apps: [HubApp]
    var on: Bool
    var allowed: Set<String>
}

/// Two-way call audio as 16 kHz mono PCM, the format the Echo sends and plays.
final class HubAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var isMuted = false
    private var running = false

    var muted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return isMuted
        }
        set {
            lock.lock()
            isMuted = newValue
            lock.unlock()
        }
    }

    func start(send: @escaping @Sendable (Data) -> Void) throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw TVError.closed }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.capture(buffer, converter, send)
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(_ pcm: Data) {
        let count = pcm.count / 2
        guard running, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                output[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func capture(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, _ send: (Data) -> Void) {
        guard !muted else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else { return }
        var data = Data(capacity: Int(output.frameLength) * 2)
        for index in 0..<Int(output.frameLength) {
            let value = Int16(max(-1, min(1, samples[index])) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        send(data)
    }
}

/// Talks to the hub on the Echo. Tailscale encrypts the connection and keeps it off the public internet.
@MainActor
final class HubController: ObservableObject {
    enum Status: Equatable {
        case needsPair, connecting, online
        case failed(String)
    }

    static let port = 8770

    @Published var host = UserDefaults.standard.string(forKey: "hubHost") ?? ""
    @Published var status: Status = .needsPair
    @Published var phase = "idle"
    @Published var note = ""
    @Published var camera: UIImage?
    @Published var screen: UIImage?
    @Published var viewing: String?
    @Published var viewNote = ""
    @Published var screens: [HubScreen] = []
    @Published var muted = false {
        didSet { audio.muted = muted }
    }

    private var connection: NWConnection?
    private var usedSavedToken = false
    private let audio = HubAudio()

    private var address: String { host.trimmingCharacters(in: .whitespaces) }
    private var account: String { "hub.\(address)" }

    static func isTailscale(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part).flatMap { $0 <= 255 ? $0 : nil }
        }
        return parts.count == 4 && octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    func connect(code: String? = nil) async {
        guard connection == nil else { return }
        guard Self.isTailscale(address), let url = URL(string: "ws://\(address):\(Self.port)") else {
            status = host.isEmpty ? .needsPair : .failed("Enter the Tailscale address shown on the Echo, like 100.101.102.103.")
            return
        }
        let saved = LGVault.read(account)
        guard code != nil || saved != nil else {
            status = .needsPair
            return
        }
        status = .connecting
        note = ""
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 8_000_000
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let candidate = NWConnection(to: .url(url), using: parameters)
        do {
            try await Net.ready(candidate, timeout: 12)
        } catch {
            candidate.cancel()
            status = .failed("Can't reach the Echo. Turn on Tailscale on this iPhone and check the Echo is online.")
            return
        }
        candidate.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.dropped(candidate) }
            default: break
            }
        }
        connection = candidate
        receive(on: candidate)
        if let code {
            usedSavedToken = false
            send(["t": "pair", "code": code])
        } else if let saved {
            usedSavedToken = true
            send(["t": "hello", "token": saved])
        }
    }

    func leave() {
        if phase != "idle" { hangUp() }
        if viewing != nil { view(nil) }
        connection?.cancel()
    }

    func startCall(_ mode: String) {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                note = "Allow Microphone for TV Control in Settings."
                return
            }
            note = ""
            send(["t": "call", "mode": mode])
        }
    }

    func hangUp() { send(["t": "hangup"]) }

    func view(_ id: String?) {
        viewNote = ""
        send(["t": "view", "screen": id.map { $0 as Any } ?? NSNull()])
    }

    func refresh() { send(["t": "state"]) }

    func setLimit(_ screenID: String, on: Bool) {
        update(screenID) { item in
            // Starting from everything allowed means turning this on never blocks an app by surprise.
            if on, item.allowed.isEmpty { item.allowed = Set(item.apps.map(\.id)) }
            item.on = on
        }
    }

    func setAllowed(_ screenID: String, app: String, allowed: Bool) {
        update(screenID) { item in
            if allowed { item.allowed.insert(app) } else { item.allowed.remove(app) }
        }
    }

    private func update(_ screenID: String, _ change: (inout HubScreen) -> Void) {
        guard let index = screens.firstIndex(where: { $0.id == screenID }) else { return }
        change(&screens[index])
        let item = screens[index]
        send(["t": "rule", "screen": item.id, "on": item.on, "allowed": Array(item.allowed)])
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let text = LGMessage.encode(object) else { return }
        WS.send(connection, text)
    }

    private func receive(on current: NWConnection) {
        current.receiveMessage { [weak self] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { @MainActor in
                guard let self, self.connection === current else { return }
                if error != nil || opcode == .close || opcode == nil {
                    self.dropped(current)
                    return
                }
                if let data, opcode == .text {
                    self.handle(String(decoding: data, as: UTF8.self))
                } else if let data, opcode == .binary {
                    self.handle(binary: data)
                }
                self.receive(on: current)
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = LGMessage.decode(text) else { return }
        switch message["t"] as? String {
        case "ready":
            status = .online
            refresh()
        case "paired":
            if let token = message["token"] as? String { LGVault.write(token, account) }
            UserDefaults.standard.set(address, forKey: "hubHost")
            status = .online
            refresh()
        case "denied":
            if usedSavedToken { LGVault.delete(account) }
            status = .failed(message["note"] as? String ?? "This iPhone needs to pair again.")
        case "state":
            screens = (message["screens"] as? [[String: Any]] ?? []).compactMap(Self.parseScreen)
        case "call":
            let next = message["phase"] as? String ?? "idle"
            if let text = message["note"] as? String, !text.isEmpty { note = text }
            guard next != "busy" else { return }
            phase = next
            if next == "live" {
                startAudio()
            } else if next == "idle" {
                audio.stop()
                camera = nil
                muted = false
            }
        case "view":
            viewing = message["screen"] as? String
            if viewing == nil { screen = nil }
            if let error = message["error"] as? String { note = error }
        case "viewNote":
            viewNote = message["text"] as? String ?? ""
        case "note":
            note = message["text"] as? String ?? ""
        default:
            break
        }
    }

    private func handle(binary data: Data) {
        guard let kind = data.first else { return }
        let body = Data(data.dropFirst())
        switch kind {
        case 1:
            camera = UIImage(data: body)
            send(["t": "ack"])
        case 2:
            audio.play(body)
        case 3:
            screen = UIImage(data: body)
        default:
            break
        }
    }

    private func startAudio() {
        guard let current = connection else { return }
        do {
            try audio.start { pcm in
                var frame = Data([2])
                frame.append(pcm)
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "audio", metadata: [metadata])
                current.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            }
        } catch {
            note = "Couldn't start the microphone."
        }
    }

    private func dropped(_ closed: NWConnection) {
        guard connection === closed else { return }
        connection = nil
        closed.cancel()
        audio.stop()
        phase = "idle"
        camera = nil
        screen = nil
        viewing = nil
        if status == .online || status == .connecting {
            status = .failed("Lost the connection to the Echo.")
        }
    }

    private static func parseScreen(_ raw: [String: Any]) -> HubScreen? {
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        let apps = (raw["apps"] as? [[String: Any]] ?? []).compactMap { app -> HubApp? in
            guard let id = app["id"] as? String, let name = app["name"] as? String else { return nil }
            return HubApp(id: id, name: name)
        }
        return HubScreen(id: id, name: name, online: raw["online"] as? Bool ?? false, apps: apps,
                         on: raw["on"] as? Bool ?? false, allowed: Set(raw["allowed"] as? [String] ?? []))
    }
}

struct HomeTab: View {
    @StateObject private var hub = HubController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var selected = "echo"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if hub.status == .online {
                        callSection
                        tvSection
                        appsSection
                    } else {
                        pairSection
                    }
                    if !hub.note.isEmpty {
                        Text(hub.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task { await hub.connect() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await hub.connect() }
            } else if newPhase == .background {
                hub.leave()
            }
        }
    }

    private var pairSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to your Echo").font(.title2.weight(.bold))
            Text("Turn on Tailscale here and on the Echo. On the Echo, open TV Control, tap Away, then Pair iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Tailscale address", text: $hub.host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .padding(12)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
            Button {
                let current = code
                code = ""
                Task { await hub.connect(code: current.isEmpty ? nil : current) }
            } label: {
                Text(hub.status == .connecting ? "Connecting…" : "Connect")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(hub.status == .connecting)
            if case .failed(let message) = hub.status {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var callSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Echo camera").font(.title2.weight(.bold))
            picture(hub.camera, hub.phase == "ringing" ? "Ringing the Echo…" : "Camera is off")
            if hub.phase == "idle" {
                HStack(spacing: 10) {
                    wideButton("Call", "phone.fill") { hub.startCall("call") }
                    wideButton("Look in", "video.fill") { hub.startCall("look") }
                }
                Text("Call rings so they can answer. Look in connects right away. Either way, the Echo chimes and shows LIVE.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    wideButton(hub.muted ? "Unmute" : "Mute", hub.muted ? "mic.slash.fill" : "mic.fill") { hub.muted.toggle() }
                    wideButton("End", "phone.down.fill") { hub.hangUp() }
                }
            }
        }
    }

    private var tvSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("See the TV").font(.title2.weight(.bold))
            if hub.viewing != nil {
                picture(hub.screen, "Loading the TV screen…")
                if !hub.viewNote.isEmpty {
                    Text(hub.viewNote).font(.footnote).foregroundStyle(.secondary)
                }
                wideButton("Stop viewing", "stop.fill") { hub.view(nil) }
            } else {
                HStack(spacing: 10) {
                    wideButton("Google TV", "tv") { hub.view("google") }
                    wideButton("LG TV", "tv") { hub.view("lg") }
                }
                Text("The TV shows a notice while you're viewing. Netflix, HBO Max and similar apps appear black.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Allowed apps").font(.title2.weight(.bold))
                Spacer()
                Button("Refresh") { hub.refresh() }.font(.subheadline)
            }
            Picker("Screen", selection: $selected) {
                ForEach(hub.screens) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            if let item = hub.screens.first(where: { $0.id == selected }) {
                if !item.online {
                    Text("\(item.name) is off or can't be reached.").font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Only allow the apps below", isOn: Binding(
                    get: { item.on },
                    set: { hub.setLimit(item.id, on: $0) }
                ))
                .padding(12)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                if item.on {
                    LazyVStack(spacing: 0) {
                        ForEach(item.apps) { app in
                            Toggle(app.name, isOn: Binding(
                                get: { item.allowed.contains(app.id) },
                                set: { hub.setAllowed(item.id, app: app.id, allowed: $0) }
                            ))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 48)
                        }
                    }
                    .background(surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func picture(_ image: UIImage?, _ placeholder: String) -> some View {
        ZStack {
            surface
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(placeholder).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func wideButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
