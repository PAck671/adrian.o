import SwiftUI
import Observation

@main
struct FamilyScreenApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// Joins the kid's Realtime channel, pings "watch" every 5 s (the phone only sends frames while pinged),
/// and shows each JPEG frame as it arrives.
@MainActor @Observable
final class ScreenFeed {
    var frame: UIImage?
    var lastFrameAt: Date?
    var connected = false

    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var code = ""
    private var ref = 0
    private var joinRef = "1"
    private var running = false

    private var topic: String { "realtime:family-\(code)" }

    func start(code: String) {
        stop()
        self.code = code
        running = true
        connect()
    }

    func stop() {
        running = false
        listener?.cancel()
        pinger?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    private func connect() {
        guard running, var comps = URLComponents(string: Config.SUPABASE_URL) else { return }
        comps.scheme = "wss"
        comps.path = "/realtime/v1/websocket"
        comps.queryItems = [URLQueryItem(name: "apikey", value: Config.SUPABASE_ANON_KEY),
                            URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let url = comps.url else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        socket = task
        task.resume()
        push("phx_join", ["config": ["broadcast": ["self": false], "presence": ["key": ""]]])

        listener = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message)
                } catch {
                    self?.retry(after: task)
                    return
                }
            }
        }
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                self?.push("heartbeat", [:], topic: "phoenix")
                self?.push("broadcast", ["type": "broadcast", "event": "watch", "payload": [:]])
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func retry(after task: URLSessionWebSocketTask) {
        guard running, task === socket else { return }
        connected = false
        pinger?.cancel()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.connect()
        }
    }

    private func push(_ event: String, _ payload: [String: Any], topic: String? = nil) {
        ref += 1
        if event == "phx_join" { joinRef = String(ref) }
        var message: [String: Any] = ["topic": topic ?? self.topic, "event": event, "payload": payload, "ref": String(ref)]
        if topic == nil { message["join_ref"] = joinRef }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(text): data = text.data(using: .utf8)
        case let .data(raw): data = raw
        @unknown default: data = nil
        }
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if obj["event"] as? String == "phx_reply" { connected = true }
        guard obj["event"] as? String == "broadcast",
              let outer = obj["payload"] as? [String: Any], outer["event"] as? String == "frame",
              let inner = outer["payload"] as? [String: Any],
              let b64 = inner["jpg"] as? String,
              let jpg = Data(base64Encoded: b64),
              let image = UIImage(data: jpg) else { return }
        frame = image
        lastFrameAt = .now
    }
}

struct ContentView: View {
    @AppStorage("familyCode") private var savedCode = ""
    @State private var entry = ""
    @State private var feed = ScreenFeed()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        if savedCode.isEmpty { codeEntry } else { viewer }
    }

    private var codeEntry: some View {
        VStack(spacing: 20) {
            Text("Family Screen").font(.largeTitle.bold())
            Text("Open Family Screen on your kid's phone and type the code it shows.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            TextField("Family code", text: $entry)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.title2.monospaced())
                .multilineTextAlignment(.center)
                .padding().background(.quaternary, in: .rect(cornerRadius: 12))
            Button("Connect") { savedCode = normalized(entry) }
                .buttonStyle(.borderedProminent)
                .disabled(normalized(entry).count < 6)
        }
        .padding(32)
    }

    private var viewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = feed.frame {
                Image(uiImage: frame).resizable().scaledToFit().accessibilityLabel("Kid's screen")
            }
            VStack {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        statusPill(now: context.date)
                    }
                    Spacer()
                    Menu {
                        Button("Change code", role: .destructive) { feed.stop(); savedCode = "" }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2).padding(8)
                    }
                    .accessibilityLabel("Options")
                }
                .padding()
                Spacer()
            }
        }
        .onAppear { feed.start(code: savedCode) }
        .onChange(of: phase) { _, now in
            // Stop pinging in the background so the kid's phone stops sending frames.
            if now == .active { feed.start(code: savedCode) } else { feed.stop() }
        }
    }

    private func statusPill(now: Date) -> some View {
        let live = feed.lastFrameAt.map { now.timeIntervalSince($0) < 5 } ?? false
        let text = live ? "Live" : (feed.connected ? "Waiting for the phone… (is sharing on?)" : "Connecting…")
        return Label(text, systemImage: live ? "dot.radiowaves.left.and.right" : "hourglass")
            .font(.footnote.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(live ? Color.red : Color.gray.opacity(0.6), in: .capsule)
            .foregroundStyle(.white)
    }

    private func normalized(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
