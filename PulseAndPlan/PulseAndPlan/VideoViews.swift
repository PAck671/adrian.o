@preconcurrency import AVFoundation
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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

    private(set) var device: AVCaptureDevice?

    /// Back camera prefers the multi-lens virtual device so 0.5×/1×/tele switch seamlessly, like the Camera app.
    func useCamera(front: Bool) -> Bool {
        let backTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = front
            ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            : backTypes.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
        guard let found, let input = try? AVCaptureDeviceInput(device: found) else { return false }
        for old in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where old.device.hasMediaType(.video) {
            session.removeInput(old)
        }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        device = found
        return true
    }

    func mirror(_ front: Bool) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
    }

    func zoomPresets() -> [ZoomPreset] {
        guard let device else { return [] }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let ultraWideBased = [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera].contains(device.deviceType)
        let wide: CGFloat = ultraWideBased ? (switches.first ?? 2) : 1
        var presets = [ZoomPreset(label: "1×", factor: wide)]
        if ultraWideBased { presets.insert(ZoomPreset(label: "0.5×", factor: 1), at: 0) }
        let tele = ultraWideBased ? switches.dropFirst().first : switches.first
        presets.append(tele.map { ZoomPreset(label: "\(Int(($0 / wide).rounded()))×", factor: $0) }
                       ?? ZoomPreset(label: "2×", factor: wide * 2))
        return presets
    }

    @discardableResult
    func zoom(to factor: CGFloat, smooth: Bool) -> CGFloat {
        guard let device, (try? device.lockForConfiguration()) != nil else { return 1 }
        defer { device.unlockForConfiguration() }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 15))
        if smooth { device.ramp(toVideoZoomFactor: clamped, withRate: 8) } else { device.videoZoomFactor = clamped }
        return clamped
    }

    func setTorch(_ on: Bool) -> Bool {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return false }
        defer { device.unlockForConfiguration() }
        device.torchMode = on ? .on : .off
        return on
    }
}

struct ZoomPreset: Hashable {
    let label: String
    let factor: CGFloat
}

@Observable
@MainActor
final class CameraModel: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Status: Equatable { case idle, ready, unavailable(String) }

    var status: Status = .idle
    var isRecording = false
    var recordStart: Date?
    var usingFront = true
    var zoomPresets: [ZoomPreset] = []
    var zoom: CGFloat = 1
    var torchOn = false
    let box = CaptureBox()
    @ObservationIgnored var onFinished: ((URL, Double) -> Void)?
    @ObservationIgnored private var pinchStart: CGFloat?

    private func refreshLens() async {
        let box = box
        let (presets, factor) = await withCheckedContinuation { continuation in
            box.queue.async {
                let presets = box.zoomPresets()
                let factor = box.zoom(to: presets.first { $0.label == "1×" }?.factor ?? 1, smooth: false)
                continuation.resume(returning: (presets, factor))
            }
        }
        zoomPresets = presets
        zoom = factor
        torchOn = false
    }

    func setZoom(_ factor: CGFloat, smooth: Bool = true) {
        zoom = factor
        let box = box
        box.queue.async { box.zoom(to: factor, smooth: smooth) }
    }

    func pinch(_ magnification: CGFloat) {
        if pinchStart == nil { pinchStart = zoom }
        setZoom((pinchStart ?? 1) * magnification, smooth: false)
    }

    func endPinch() { pinchStart = nil }

    func toggleTorch() {
        let box = box, want = !torchOn
        box.queue.async {
            let on = box.setTorch(want)
            Task { @MainActor in self.torchOn = on }
        }
    }

    /// Restarts the preview after the system camera (which needs the hardware to itself) closes.
    func resume() {
        let box = box
        box.queue.async { if !box.session.isRunning { box.session.startRunning() } }
    }

    static let maxDuration = 60.0

    func configure() async {
        guard status == .idle else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = .unavailable("Camera access is off. Turn it on in iOS Settings → Red Thread.")
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
        if ok { await refreshLens() }
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
        Task { await refreshLens() }
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
    @State private var systemPicker: PickerSource?

    struct PickerSource: Identifiable {
        let source: UIImagePickerController.SourceType
        var id: Int { source.rawValue }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 22) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                    .accessibilityLabel("Close")
                Spacer()
                if camera.status == .ready, !camera.usingFront {
                    Button { camera.toggleTorch() } label: {
                        Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(camera.torchOn ? "Turn light off" : "Turn light on")
                }
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
                        .gesture(MagnifyGesture()
                            .onChanged { camera.pinch($0.magnification) }
                            .onEnded { _ in camera.endPinch() })
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

            if camera.status == .ready, camera.zoomPresets.count > 1 {
                HStack(spacing: 10) {
                    ForEach(camera.zoomPresets, id: \.self) { preset in
                        let selected = abs(camera.zoom - preset.factor) < 0.05
                        Button { camera.setZoom(preset.factor) } label: {
                            Text(preset.label)
                                .font(.caption.bold())
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(.white.opacity(selected ? 0.3 : 0.1)))
                                .foregroundStyle(selected ? .yellow : .white)
                        }
                        .accessibilityLabel("Zoom \(preset.label)")
                    }
                }
            }
            Spacer()

            if camera.status == .ready {
                recordButton
            } else if case .unavailable = camera.status {
                Button(makingSample ? "Rendering…" : "Send a sample clip instead") { sendSample() }
                    .buttonStyle(.borderedProminent)
                    .disabled(makingSample)
            }

            HStack(spacing: 14) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        camera.shutdown()
                        systemPicker = PickerSource(source: .camera)
                    } label: { Label("iPhone Camera", systemImage: "camera.fill") }
                }
                Button { systemPicker = PickerSource(source: .photoLibrary) } label: {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(camera.isRecording)
        }
        .padding(.vertical)
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(item: $systemPicker, onDismiss: { camera.resume() }) { picker in
            SystemVideoPicker(source: picker.source) { importPicked($0) }
                .ignoresSafeArea()
        }
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

    /// Copies a clip from the system camera/Photos (its temp file vanishes after the picker closes) and sends it.
    private func importPicked(_ url: URL) {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let destination = VideoClip.directory.appending(path: "clip-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            state.showToast("Couldn't import that video: \(error.localizedDescription)")
            return
        }
        Task {
            let seconds = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
            await state.sendClip(localName: destination.lastPathComponent, duration: min(seconds, CameraModel.maxDuration))
            dismiss()
        }
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
                            .surface(Capsule())
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
                        Button("Replay") { load() }.buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .surface(RoundedRectangle(cornerRadius: 20))
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
                .surface(Capsule())
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

// MARK: - System camera / Photos

/// Apple's own camera UI (lenses, zoom, flash, exposure, HDR) or Photos with the built-in 60 s trimmer.
struct SystemVideoPicker: UIViewControllerRepresentable {
    let source: UIImagePickerController.SourceType
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoMaximumDuration = CameraModel.maxDuration
        picker.videoQuality = .typeHigh
        picker.allowsEditing = true
        if source == .camera {
            picker.cameraCaptureMode = .video
            picker.cameraDevice = .front
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, dismiss: { dismiss() }) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (URL) -> Void
        let dismiss: () -> Void

        init(onPick: @escaping (URL) -> Void, dismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { onPick(url) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
