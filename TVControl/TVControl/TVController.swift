import AVFoundation
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let destination = MediaPrep.tempFile(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum MediaPrep {
    static func tempFile(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    }

    // Large iPhone photos can stall this 1.5 GB box, so they are sized to its 1080p output.
    static func image(_ source: CGImageSource) -> URL? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return nil }
        let output = tempFile("jpg")
        return (try? jpeg.write(to: output)) == nil ? nil : output
    }

    // iPhone video is often HEVC in .mov, so it becomes 1080p H.264 MP4 for reliable TV playback.
    static func video(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw TVError.prepareFailed
        }
        let output = tempFile("mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else { throw TVError.prepareFailed }
        return output
    }
}

@MainActor
final class TVController: ObservableObject {
    enum Link: Equatable {
        case idle, connecting, approve, connected
        case failed(String)
    }

    enum Target: String, CaseIterable, Identifiable {
        case google = "Google TV"
        case lg = "LG TV"
        var id: String { rawValue }
    }

    @Published var link: Link = .idle
    @Published var host: String
    @Published var apps: [TVApp] = []
    @Published var castStatus = ""
    @Published var isCasting = false
    @Published var isPreparing = false
    @Published var notice: String?
    @Published var target: Target {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "tvTarget") }
    }
    @Published var lgLink: Link = .idle
    @Published var lgHost: String
    @Published var lgApps: [LGApp] = []
    @Published var lgInputs: [LGInput] = []

    var activeLink: Link { target == .lg ? lgLink : link }
    var activeHost: String { target == .lg ? lgHost : host }

    private let lg = LGClient()
    private var lgConnectTask: Task<Void, Never>?
    private var lgPaused = false
    private var adb: ADBClient?
    private var connectTask: Task<Void, Never>?
    private let cast = CastClient()
    private let server = MediaServer()
    private var hostedFile: URL?

    init() {
        host = UserDefaults.standard.string(forKey: "tvHost") ?? "192.168.12.183"
        lgHost = UserDefaults.standard.string(forKey: "lgHost") ?? "192.168.12.196"
        target = Target(rawValue: UserDefaults.standard.string(forKey: "tvTarget") ?? "") ?? .google
        Task { [cast, weak self] in
            await cast.onStatus { status in
                Task { @MainActor in self?.castStatus = status }
            }
        }
    }

    func connect() async {
        if let connectTask {
            await connectTask.value
            return
        }
        let task = Task { await performConnect() }
        connectTask = task
        await task.value
        connectTask = nil
        if link == .connected, apps.isEmpty { await refreshApps() }
    }

    private func performConnect() async {
        guard TVCommands.isPrivateIPv4(host) else {
            link = .failed("Enter your TV's Wi-Fi address in the TV tab.")
            return
        }
        do {
            if adb == nil { adb = try ADBClient() }
            guard let adb else { return }
            if await adb.isConnected {
                link = .connected
                return
            }
            link = .connecting
            try await adb.connect(host: host) { [weak self] in
                Task { @MainActor in self?.link = .approve }
            }
            link = .connected
        } catch {
            link = .failed("Can't reach the TV. Check Wi-Fi and Local Network access.")
        }
    }

    @discardableResult
    func run(_ command: String) async -> String? {
        for attempt in 0..<2 {
            if await !(adb?.isConnected ?? false) { await connect() }
            guard let adb, await adb.isConnected else { return nil }
            do {
                return try await adb.shell(command)
            } catch TVError.timedOut {
                notice = TVError.timedOut.errorDescription
                return nil
            } catch {
                await adb.disconnect()
                if attempt == 1 { link = .failed("Lost the TV connection.") }
            }
        }
        return nil
    }

    func updateHost(_ newHost: String) {
        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
        guard TVCommands.isPrivateIPv4(trimmed) else {
            notice = "Enter an address like 192.168.1.20."
            return
        }
        if target == .lg {
            lgHost = trimmed
            UserDefaults.standard.set(trimmed, forKey: "lgHost")
            lgApps = []
            lgInputs = []
            Task {
                await lg.disconnect()
                await connectLG()
            }
            return
        }
        host = trimmed
        UserDefaults.standard.set(trimmed, forKey: "tvHost")
        apps = []
        Task {
            await adb?.disconnect()
            await connect()
        }
    }

    func press(_ code: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if target == .lg {
            Task { await pressLG(code) }
        } else {
            Task { await run(TVCommands.key(code)) }
        }
    }

    func send(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await run(command) }
    }

    func launch(_ app: TVApp) {
        guard let command = TVCommands.launch(app) else { return }
        send(command)
    }

    func type(_ text: String) {
        if target == .lg {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await requestLG(LGCommands.insertText, ["text": text, "replace": 0]) }
            return
        }
        guard let command = TVCommands.inputText(text) else {
            notice = "The TV can only receive plain letters, numbers and symbols."
            return
        }
        send(command)
    }

    func search(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(TVCommands.search(query))
    }

    func refreshApps() async {
        if let output = await run(TVCommands.listApps) {
            apps = TVCommands.parseApps(output)
        }
    }

    func restart() {
        Task {
            await adb?.reboot()
            await adb?.disconnect()
            link = .failed("TV is restarting. Tap Retry in a minute.")
        }
    }

    func castLink(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let action = TVCommands.classify(url) else {
            notice = "Enter a full link starting with http or https."
            return
        }
        switch action {
        case .app(let package):
            let enabled = await run("pm list packages -e") ?? ""
            await run(TVCommands.openLink(url, package: TVCommands.linkPackage(package, enabled: enabled)))
            castStatus = "Opened on TV"
        case .open:
            await run(TVCommands.openLink(url))
            castStatus = "Sent to TV"
        case .media(let type):
            await startCast(url: url.absoluteString, type: type, title: url.lastPathComponent)
        }
    }

    func castPicked(_ item: PhotosPickerItem) async {
        isPreparing = true
        defer { isPreparing = false }
        castStatus = "Preparing…"
        do {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw TVError.prepareFailed }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                castStatus = "Converting video for your TV…"
                await castHosted(try await MediaPrep.video(movie.url), type: "video/mp4", title: "Video")
            } else {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let output = MediaPrep.image(source) else { throw TVError.prepareFailed }
                await castHosted(output, type: "image/jpeg", title: "Photo")
            }
        } catch {
            castStatus = error.localizedDescription
        }
    }

    func castImported(_ url: URL) async {
        isPreparing = true
        defer { isPreparing = false }
        castStatus = "Preparing…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .movie) == true {
                castStatus = "Converting video for your TV…"
                await castHosted(try await MediaPrep.video(url), type: "video/mp4", title: url.deletingPathExtension().lastPathComponent)
            } else if type?.conforms(to: .image) == true {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let output = MediaPrep.image(source) else { throw TVError.prepareFailed }
                await castHosted(output, type: "image/jpeg", title: url.deletingPathExtension().lastPathComponent)
            } else if type?.conforms(to: .audio) == true, let mime = type?.preferredMIMEType {
                let copy = MediaPrep.tempFile(url.pathExtension)
                try FileManager.default.copyItem(at: url, to: copy)
                await castHosted(copy, type: mime, title: url.deletingPathExtension().lastPathComponent)
            } else {
                throw TVError.prepareFailed
            }
        } catch {
            castStatus = error.localizedDescription
        }
    }

    func castPlayPause() {
        Task {
            if castStatus == "Paused" { await cast.play() } else { await cast.pause() }
        }
    }

    func castSeek(_ seconds: Double) { Task { await cast.seek(by: seconds) } }
    func castVolume(_ level: Double) { Task { await cast.setVolume(level) } }

    func stopCast() {
        Task { await cast.stop() }
        server.stop()
        removeHostedFile()
        UIApplication.shared.isIdleTimerDisabled = false
        isCasting = false
        castStatus = ""
    }

    func connectActive() async {
        if target == .lg { await connectLG() } else { await connect() }
    }

    func connectLG() async {
        if let lgConnectTask {
            await lgConnectTask.value
            return
        }
        let task = Task { await performLGConnect() }
        lgConnectTask = task
        await task.value
        lgConnectTask = nil
        if lgLink == .connected, lgApps.isEmpty { await refreshLG() }
    }

    private func performLGConnect() async {
        guard TVCommands.isPrivateIPv4(lgHost) else {
            lgLink = .failed("Enter your LG TV's Wi-Fi address in the TV tab.")
            return
        }
        if await lg.isConnected {
            lgLink = .connected
            return
        }
        lgLink = .connecting
        do {
            try await lg.connect(host: lgHost) { [weak self] in
                Task { @MainActor in self?.lgLink = .approve }
            }
            lgLink = .connected
        } catch let error as TVError {
            switch error {
            case .certificateChanged, .tvRejected: lgLink = .failed(error.localizedDescription)
            default: lgLink = .failed("Can't reach the LG TV. If it's off, press Power.")
            }
        } catch {
            lgLink = .failed("Can't reach the LG TV. If it's off, press Power.")
        }
    }

    func refreshLG() async {
        if let payload = await requestLG(LGCommands.apps) { lgApps = LGCommands.parseApps(payload) }
        if let payload = await requestLG(LGCommands.inputs) { lgInputs = LGCommands.parseInputs(payload) }
    }

    func launchLG(_ app: LGApp) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await requestLG(LGCommands.launch, ["id": app.id]) }
    }

    func switchInput(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await requestLG(LGCommands.switchInput, ["inputId": id]) }
    }

    func lgButton(_ name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await sendLGButton(name) }
    }

    func wakeLG() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await wakeLGThroughBox() }
    }

    func forgetLG() {
        Task {
            await lg.forget(host: lgHost)
            lgApps = []
            lgInputs = []
            await connectLG()
        }
    }

    private func pressLG(_ code: Int) async {
        if code == TVCommands.Key.power {
            if await lg.isConnected {
                await requestLG(LGCommands.turnOff)
                await lg.disconnect()
                lgLink = .failed("LG TV is off. Press Power to turn it on.")
            } else {
                await wakeLGThroughBox()
            }
        } else if code == TVCommands.Key.playPause {
            lgPaused.toggle()
            await requestLG(lgPaused ? LGCommands.pause : LGCommands.play)
        } else if code == TVCommands.Key.home {
            await requestLG(LGCommands.launch, ["id": LGCommands.homeApp])
        } else if let name = LGCommands.button(for: code) {
            await sendLGButton(name)
        }
    }

    // The LG can't be woken over Wi-Fi from iOS, but the Google TV box can turn it on through HDMI-CEC.
    private func wakeLGThroughBox() async {
        lgLink = .connecting
        guard await run(TVCommands.key(TVCommands.Key.wakeup)) != nil else {
            lgLink = .failed("Couldn't wake the LG TV through the Google TV box.")
            return
        }
        try? await Task.sleep(for: .seconds(8))
        await connectLG()
    }

    private func sendLGButton(_ name: String) async {
        for attempt in 0..<2 {
            if await !lg.isConnected { await connectLG() }
            guard await lg.isConnected else { return }
            do {
                try await lg.button(name)
                return
            } catch TVError.tvRejected(let message) {
                notice = message
                return
            } catch {
                await lg.disconnect()
                if attempt == 1 { lgLink = .failed("Lost the LG TV connection.") }
            }
        }
    }

    @discardableResult
    private func requestLG(_ uri: String, _ payload: [String: Any] = [:]) async -> [String: Any]? {
        for attempt in 0..<2 {
            if await !lg.isConnected { await connectLG() }
            guard await lg.isConnected else { return nil }
            do {
                return try await lg.request(uri, payload)
            } catch TVError.tvRejected(let message) {
                notice = message
                return nil
            } catch TVError.timedOut {
                notice = TVError.timedOut.errorDescription
                return nil
            } catch {
                await lg.disconnect()
                if attempt == 1 { lgLink = .failed("Lost the LG TV connection.") }
            }
        }
        return nil
    }

    private func castHosted(_ file: URL, type: String, title: String) async {
        do {
            let served = try await server.publish(file, contentType: type)
            removeHostedFile()
            hostedFile = file
            // The phone is the file server, so it must stay awake while the TV plays.
            UIApplication.shared.isIdleTimerDisabled = true
            await startCast(url: served.absoluteString, type: type, title: title)
        } catch {
            castStatus = error.localizedDescription
        }
    }

    private func startCast(url: String, type: String, title: String) async {
        castStatus = "Starting on TV…"
        do {
            try await cast.load(host: host, url: url, contentType: type, title: title)
            isCasting = true
        } catch {
            castStatus = error.localizedDescription
        }
    }

    private func removeHostedFile() {
        if let hostedFile { try? FileManager.default.removeItem(at: hostedFile) }
        hostedFile = nil
    }
}
