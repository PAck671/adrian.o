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
    func sendNotice(_ notice: PartnerNotice)
    func saveNote(_ note: SharedNote)
    func deleteNote(_ id: UUID)
    func sendAvatar(_ jpeg: Data) async throws
}

// MARK: - Sample clip generator

/// Renders a short animated .mov for "Send a sample clip" on devices without a camera (e.g. the Simulator).
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
