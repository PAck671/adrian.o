@preconcurrency import AVFoundation
import UIKit

/// Transport between the two phones. AppState talks only to this protocol.
@MainActor
protocol SyncService: AnyObject {
    var onEvent: ((SyncEvent) -> Void)? { get set }
    func start()
    func stop()
    func sendPulse(_ pulse: Pulse)
    func markPulsesSeen(_ ids: [UUID])
    func sendVideo(_ clip: VideoClip) async throws
    func react(clipId: UUID, reaction: String)
    func sendSwipe(_ swipe: MovieSwipe)
    func sendLocation(_ share: LocationShare)
    func saveEvent(_ event: SharedEvent)
    func deleteEvent(_ id: UUID)
    func sendGame(_ state: GameState)
    func saveVisit(_ visit: Visit)
}

// MARK: - Demo / Solo Test partner

/// Simulates a connected partner on one phone: moving pin, pulse replies, swipes, video replies.
@MainActor
final class DemoPartnerService: SyncService {
    static let partnerId = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID()

    var onEvent: ((SyncEvent) -> Void)?
    private let city: DemoCity
    private let partnerName: String
    private let missedSince: Date?
    private let sendWelcomeClip: Bool
    private var loop: Task<Void, Never>?
    private var tick = 0
    private var battery = 82

    init(city: DemoCity, partnerName: String, missedSince: Date?, sendWelcomeClip: Bool) {
        self.city = city
        self.partnerName = partnerName
        self.missedSince = missedSince
        self.sendWelcomeClip = sendWelcomeClip
    }

    func start() {
        emit(.presence(online: true))
        emit(.status("Demo partner connected in \(city.name)"))
        // Pulses "sent while you were away" land in the Missed Pulses inbox.
        if let missedSince, Date().timeIntervalSince(missedSince) > 60 {
            for (i, pattern) in [PulsePattern.heartbeat, .doubleSqueeze, .morseTap].prefix(1 + Int.random(in: 0...2)).enumerated() {
                emit(.pulse(Pulse(senderId: Self.partnerId, pattern: pattern, sentAt: Date().addingTimeInterval(-Double(600 * (i + 1))))))
            }
        }
        if sendWelcomeClip { replyWithClip(after: 1, text: "Hi from \(city.name)!") }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.step()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func emit(_ event: SyncEvent) { onEvent?(event) }

    private func after(_ seconds: Double, _ work: @escaping @MainActor @Sendable () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    /// Partner walks Home → Campus → Home on a loop, pausing at each end (arrival badges).
    private func step() {
        tick += 1
        let c = tick % 50
        let p: Double = c < 10 ? 0 : c < 25 ? Double(c - 10) / 15 : c < 35 ? 1 : 1 - Double(c - 35) / 15
        let wobble = sin(p * .pi) * 0.004
        let lat = city.lat + 0.012 * p + wobble
        let lng = city.lng + 0.018 * p - wobble
        if tick % 10 == 0 { battery = p == 0 ? min(100, battery + 3) : max(6, battery - 1) }
        let label = p == 0 ? "At Home" : p == 1 ? "At Campus" : nil
        emit(.location(LocationShare(userId: Self.partnerId, lat: lat, lng: lng, precision: .live,
                                     battery: battery, placeLabel: label, city: city.name)))
        if tick % 25 == 12 {
            let pattern = [PulsePattern.heartbeat, .doubleSqueeze, .tap, .morseTap].randomElement() ?? .heartbeat
            emit(.pulse(Pulse(senderId: Self.partnerId, pattern: pattern)))
        }
    }

    func sendPulse(_ pulse: Pulse) {
        let reply = pulse.pattern == .hold ? PulsePattern.heartbeat : pulse.pattern
        after(Double.random(in: 1.5...3)) { [weak self] in
            self?.emit(.pulse(Pulse(senderId: Self.partnerId, pattern: reply)))
        }
    }

    func markPulsesSeen(_ ids: [UUID]) {}

    func sendVideo(_ clip: VideoClip) async throws {
        replyWithClip(after: 5, text: "Loved your clip!")
    }

    func react(clipId: UUID, reaction: String) {}

    func sendSwipe(_ swipe: MovieSwipe) {
        let liked = Self.partnerLikes(swipe.movieId)
        after(0.8) { [weak self] in
            self?.emit(.swipe(MovieSwipe(userId: Self.partnerId, movieId: swipe.movieId, liked: liked)))
        }
    }

    /// Fixed ~60% taste so matches are reproducible while testing.
    nonisolated static func partnerLikes(_ movieId: Int) -> Bool { (movieId * 7 + 3) % 10 < 6 }

    func sendLocation(_ share: LocationShare) {}
    func saveEvent(_ event: SharedEvent) {}
    func deleteEvent(_ id: UUID) {}
    func sendGame(_ state: GameState) {}
    func saveVisit(_ visit: Visit) {}

    private func replyWithClip(after seconds: Double, text: String) {
        let avatar = partnerName
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let name = try? await DemoClipMaker.make(text: text, caption: "— \(avatar)") else { return }
            self?.emit(.video(VideoClip(senderId: Self.partnerId, localName: name, duration: DemoClipMaker.duration)))
        }
    }
}

// MARK: - Demo clip generator

/// Renders a short animated .mov so the reel has real partner videos in Demo mode (and in the Simulator).
enum DemoClipMaker {
    static let duration = 3.0
    private static let side = 480

    static func make(text: String, caption: String) async throws -> String {
        let name = "demo-\(UUID().uuidString).mov"
        let url = VideoClip.directory.appending(path: name)
        try await Task.detached(priority: .utility) {
            try await render(to: url, text: text, caption: caption)
        }.value
        return name
    }

    private static func render(to url: URL, text: String, caption: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 24
        let frames = Int(duration * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            draw(into: buffer, progress: Double(frame) / Double(frames), text: text, caption: caption)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func draw(into buffer: CVPixelBuffer, progress: Double, text: String, caption: String) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1) // UIKit drawing expects a top-left origin
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let s = CGFloat(side)
        UIColor(hue: 0.9 + 0.1 * progress, saturation: 0.6, brightness: 0.55, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: s, height: s))

        let beat = 1 + 0.15 * sin(progress * .pi * 6)
        let heart = NSAttributedString(string: "❤️", attributes: [.font: UIFont.systemFont(ofSize: 120 * beat)])
        let hs = heart.size()
        heart.draw(at: CGPoint(x: (s - hs.width) / 2, y: s * 0.38 - hs.height / 2))

        for (string, size, y) in [(text, 34.0, 0.68), (caption, 22.0, 0.80)] {
            let line = NSAttributedString(string: string, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: UIColor.white,
            ])
            let ls = line.size()
            line.draw(at: CGPoint(x: (s - ls.width) / 2, y: s * y))
        }
    }
}
