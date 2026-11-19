@preconcurrency import CoreHaptics
import UIKit

/// CoreHaptics wrapper. Falls back to UIKit feedback where the hardware has no Taptic Engine (e.g. Simulator).
@MainActor
final class HapticEngine {
    private var engine: CHHapticEngine?
    private var holdPlayer: CHHapticAdvancedPatternPlayer?
    private var holdStart: Date?
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init() {
        guard supported else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.isAutoShutdownEnabled = true
    }

    func play(_ pattern: PulsePattern, duration: Double = 0.6) {
        guard let engine else { return fallback(pattern) }
        do {
            try engine.start() // cheap when running; also recovers after a reset or auto-shutdown
            let player = try engine.makePlayer(with: CHHapticPattern(events: Self.events(for: pattern, duration: duration), parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback(pattern)
        }
    }

    /// Live "hold": buzzes while the finger is down.
    func beginHold() {
        holdStart = Date()
        guard let engine else { return UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        do {
            try engine.start()
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [Self.buzz(0, 30, 0.7, 0.2)], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            holdPlayer = player
        } catch {}
    }

    /// Returns how long the hold lasted.
    @discardableResult
    func endHold() -> Double {
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
        defer { holdStart = nil }
        return holdStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    func bump() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }

    private func fallback(_ pattern: PulsePattern) {
        let generator = UIImpactFeedbackGenerator(style: pattern == .tap ? .medium : .heavy)
        generator.impactOccurred()
    }

    // MARK: Patterns

    nonisolated static func events(for pattern: PulsePattern, duration: Double) -> [CHHapticEvent] {
        switch pattern {
        case .tap:
            return [tap(0)]
        case .hold:
            return [buzz(0, min(max(duration, 0.15), 5))]
        case .heartbeat:
            return [0, 0.9, 1.8].flatMap { [tap($0, 1, 0.3), tap($0 + 0.16, 0.6, 0.2)] }
        case .doubleSqueeze:
            return [buzz(0, 0.22, 1, 0.2), buzz(0.36, 0.22, 1, 0.2)]
        case .morseTap:
            var t = 0.0
            var out: [CHHapticEvent] = []
            for letter in ["..", ".-..", "-.--"] { // I · L · Y
                for symbol in letter {
                    out.append(symbol == "." ? tap(t, 0.9, 0.8) : buzz(t, 0.3, 0.9, 0.6))
                    t += (symbol == "." ? 0.1 : 0.3) + 0.12
                }
                t += 0.35
            }
            return out
        }
    }

    nonisolated private static func tap(_ time: Double, _ intensity: Float = 1, _ sharpness: Float = 0.5) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    nonisolated private static func buzz(_ time: Double, _ duration: Double, _ intensity: Float = 0.8, _ sharpness: Float = 0.3) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time, duration: duration)
    }
}
