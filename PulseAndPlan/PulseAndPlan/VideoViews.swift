@preconcurrency import AVFoundation
import AVKit
import Combine
import SwiftUI

// MARK: - Camera

/// Capture objects live here and are only touched on `queue` (AVCaptureSession calls block).
final class CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
    let queue = DispatchQueue(label: "pulse.camera")

    func configure(front: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard useCamera(front: front) else { return false }
        if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
        mirror(front)
        return true
    }

    func useCamera(front: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        for old in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where old.device.hasMediaType(.video) {
            session.removeInput(old)
        }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    func mirror(_ front: Bool) {
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
    }
}

@Observable
@MainActor
final class CameraModel: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Status: Equatable { case idle, ready, unavailable(String) }

    var status: Status = .idle
    var isRecording = false
    var recordStart: Date?
    var usingFront = true
    let box = CaptureBox()
    @ObservationIgnored var onFinished: ((URL, Double) -> Void)?

    static let maxDuration = 60.0

    func configure() async {
        guard status == .idle else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = .unavailable("Camera access is off. Turn it on in iOS Settings → Pulse & Plan.")
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let box = box, front = usingFront
        let ok = await withCheckedContinuation { continuation in
            box.queue.async {
                let ok = box.configure(front: front)
                if ok { box.session.startRunning() }
                continuation.resume(returning: ok)
            }
        }
        status = ok ? .ready : .unavailable("No camera on this device (e.g. the Simulator).")
    }

    func flip() {
        guard status == .ready, !isRecording else { return }
        usingFront.toggle()
        let box = box, front = usingFront
        box.queue.async {
            box.session.beginConfiguration()
            _ = box.useCamera(front: front)
            box.mirror(front)
            box.session.commitConfiguration()
        }
    }

    func startRecording() {
        guard status == .ready, !isRecording else { return }
        let url = VideoClip.directory.appending(path: "clip-\(UUID().uuidString).mov")
        isRecording = true
        recordStart = Date()
        let box = box
        box.queue.async { box.output.startRecording(to: url, recordingDelegate: self) }
    }

    func stopRecording() {
        guard isRecording else { return }
        let box = box
        box.queue.async { box.output.stopRecording() }
    }

    func shutdown() {
        let box = box
        box.queue.async {
            if box.output.isRecording { box.output.stopRecording() }
            box.session.stopRunning()
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: (any Error)?) {
        // Hitting the 60 s cap reports an error, but the file is complete.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        Task { @MainActor in self.didFinish(url: outputFileURL, ok: finished) }
    }

    private func didFinish(url: URL, ok: Bool) {
        isRecording = false
        let duration = min(recordStart.map { Date().timeIntervalSince($0) } ?? 0, Self.maxDuration)
        recordStart = nil
        if ok, duration > 0.3 {
            onFinished?(url, duration)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer?.session = session
        view.previewLayer?.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Composer

struct VideoComposer: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraModel()
    @State private var pressStart: Date?
    @State private var startedByPress = false
    @State private var makingSample = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                    .accessibilityLabel("Close")
                Spacer()
                Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2) }
                    .disabled(camera.status != .ready || camera.isRecording)
                    .accessibilityLabel("Switch camera")
            }
            .padding(.horizontal)
            .foregroundStyle(.white)

            Spacer()
            ZStack {
                switch camera.status {
                case .ready:
                    CameraPreview(session: camera.box.session)
                case .idle:
                    Color.white.opacity(0.06).overlay(ProgressView())
                case let .unavailable(message):
                    Color.white.opacity(0.06).overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash.fill").font(.largeTitle)
                            Text(message).font(.footnote).multilineTextAlignment(.center)
                        }
                        .padding(40)
                        .foregroundStyle(.secondary))
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(Circle())
            .overlay {
                TimelineView(.animation(paused: !camera.isRecording)) { context in
                    Circle()
                        .trim(from: 0, to: progress(at: context.date))
                        .stroke(.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(-6)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(camera.isRecording ? "\(timeText(at: context.date)) / 1:00" : "Tap to record · hold for push-to-talk")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if camera.status == .ready {
                recordButton
            } else if case .unavailable = camera.status {
                Button(makingSample ? "Rendering…" : "Send a sample clip instead") { sendSample() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(makingSample)
            }
        }
        .padding(.vertical)
        .background(Color.black.ignoresSafeArea())
        .task {
            camera.onFinished = { url, duration in
                Task {
                    await state.sendClip(localName: url.lastPathComponent, duration: duration)
                    dismiss()
                }
            }
            await camera.configure()
        }
        .onDisappear { camera.shutdown() }
    }

    private var recordButton: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 5).frame(width: 86, height: 86)
            RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 35)
                .fill(.red)
                .frame(width: camera.isRecording ? 36 : 70, height: camera.isRecording ? 36 : 70)
                .animation(.spring(duration: 0.25), value: camera.isRecording)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    if camera.isRecording {
                        camera.stopRecording()
                        startedByPress = false
                    } else {
                        camera.startRecording()
                        startedByPress = true
                    }
                }
                .onEnded { _ in
                    // Long press = push-to-talk (stop on release); short tap = keep recording until next tap.
                    if startedByPress, let start = pressStart, Date().timeIntervalSince(start) > 0.5 {
                        camera.stopRecording()
                    }
                    pressStart = nil
                    startedByPress = false
                }
        )
        .accessibilityElement()
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Record")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { camera.isRecording ? camera.stopRecording() : camera.startRecording() }
    }

    private func progress(at date: Date) -> CGFloat {
        guard let start = camera.recordStart else { return 0 }
        return min(date.timeIntervalSince(start) / CameraModel.maxDuration, 1)
    }

    private func timeText(at date: Date) -> String {
        let seconds = Int(camera.recordStart.map { date.timeIntervalSince($0) } ?? 0)
        return String(format: "0:%02d", min(seconds, 60))
    }

    private func sendSample() {
        makingSample = true
        Task {
            if let name = try? await DemoClipMaker.make(text: "Hello from \(state.settings.myName)!", caption: "sample clip") {
                await state.sendClip(localName: name, duration: DemoClipMaker.duration)
            }
            makingSample = false
            dismiss()
        }
    }
}

// MARK: - Reel

struct ReelPlayer: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let startClip: VideoClip
    @State private var player = AVQueuePlayer()
    @State private var itemClips: [ObjectIdentifier: UUID] = [:]
    @State private var currentId: UUID?
    @State private var rate: Float = 1

    private static let reactions = ["❤️", "😂", "😮", "🥺", "🔥"]

    var body: some View {
        ZStack {
            VideoPlayer(player: player).ignoresSafeArea()
            VStack {
                HStack {
                    if let clip = current {
                        let mine = !state.isPartner(clip.senderId)
                        Text("\(mine ? state.settings.myAvatar : state.settings.partnerAvatar) \(mine ? "You" : state.settings.partnerName) · \(clip.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.subheadline.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Close reel")
                }
                Spacer()
                if current == nil {
                    VStack(spacing: 12) {
                        Text("You're all caught up ✨").font(.title3.bold())
                        Button("Replay") { load() }.buttonStyle(.borderedProminent).tint(.pink)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    Spacer()
                }
                HStack(spacing: 14) {
                    ForEach(Self.reactions, id: \.self) { emoji in
                        Button {
                            if let clip = current { state.react(clip, emoji) }
                            state.haptics.play(.tap)
                        } label: {
                            Text(emoji)
                                .font(.title2)
                                .scaleEffect(current?.reaction == emoji ? 1.3 : 1)
                        }
                        .accessibilityLabel("React \(emoji)")
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())
                Picker("Speed", selection: $rate) {
                    Text("1×").tag(Float(1))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2))
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding()
        }
        .background(Color.black)
        .onAppear(perform: load)
        .onDisappear { player.pause() }
        .onChange(of: rate) { _, newRate in
            player.defaultRate = newRate
            if player.timeControlStatus != .paused { player.rate = newRate }
        }
        .onReceive(player.publisher(for: \.currentItem).receive(on: RunLoop.main)) { item in
            currentId = item.flatMap { itemClips[ObjectIdentifier($0)] }
        }
    }

    private var current: VideoClip? { currentId.flatMap { id in state.clips.first { $0.id == id } } }

    /// Auto-queues the tapped clip and every later one, oldest first.
    private func load() {
        player.removeAllItems()
        var map: [ObjectIdentifier: UUID] = [:]
        for clip in state.clips.drop(while: { $0.id != startClip.id }) {
            guard let url = clip.playbackURL else { continue }
            let item = AVPlayerItem(url: url)
            map[ObjectIdentifier(item)] = clip.id
            player.insert(item, after: nil)
        }
        itemClips = map
        currentId = player.currentItem.flatMap { map[ObjectIdentifier($0)] }
        player.defaultRate = rate
        player.play()
        player.rate = rate
    }
}
