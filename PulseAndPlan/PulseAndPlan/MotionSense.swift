@preconcurrency import CoreMotion
import Foundation
import Observation

/// What the motion coprocessor reports (walking, driving…), independent of how the phone is held.
enum Transport: Sendable {
    case stationary, walking, running, cycling, automotive, unknown
}

/// Guesses what you're doing from every sensor iOS offers without a paid entitlement:
/// - Motion coprocessor (CMMotionActivity): stationary / walking / running / cycling / automotive.
/// - Gyroscope + accelerometer + gravity (CMDeviceMotion): is the phone resting, held, flat, face-down, held overhead?
/// - GPS speed (from LocationManager): separates car vs train vs plane, and is the fallback without the coprocessor.
/// A label only changes after it has held steady for a few seconds, so picking the phone up doesn't flicker it.
@Observable
@MainActor
final class MotionSense {
    private(set) var activity: PartnerActivity?
    @ObservationIgnored var onChange: ((PartnerActivity?) -> Void)?

    struct Sample: Sendable {
        let gx: Double, gy: Double, gz: Double
        let rotation: Double       // rad/s magnitude (gyroscope)
        let acceleration: Double   // g, gravity removed
    }

    @ObservationIgnored private let activityManager = CMMotionActivityManager()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pulse.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    @ObservationIgnored private var transport: Transport = .unknown
    @ObservationIgnored private var speed: Double?
    @ObservationIgnored private var speedAt = Date.distantPast
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var candidate: PartnerActivity?
    @ObservationIgnored private var candidateSince = Date()
    @ObservationIgnored private(set) var running = false

    static let settleSeconds = 8.0

    func start() {
        guard !running else { return }
        running = true
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: queue, withHandler: Self.activityHandler(self))
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.5 // 2 Hz: enough for posture, cheap on battery
            motion.startDeviceMotionUpdates(to: queue, withHandler: Self.motionHandler(self))
        }
    }

    func stop() {
        guard running else { return }
        activityManager.stopActivityUpdates()
        motion.stopDeviceMotionUpdates()
        running = false
        samples = []
        candidate = nil
        activity = nil
        onChange?(nil)
    }

    /// GPS speed in m/s (negative = invalid).
    func updateSpeed(_ metersPerSecond: Double) {
        speed = metersPerSecond >= 0 ? metersPerSecond : nil
        speedAt = Date()
        evaluate()
    }

    // Handlers are built outside the main actor: CoreMotion calls them on `queue`.
    nonisolated private static func activityHandler(_ owner: MotionSense) -> CMMotionActivityHandler {
        { activity in
            guard let activity, activity.confidence != .low else { return }
            let transport: Transport = activity.automotive ? .automotive : activity.cycling ? .cycling
                : activity.running ? .running : activity.walking ? .walking : activity.stationary ? .stationary : .unknown
            Task { @MainActor in
                owner.transport = transport
                owner.evaluate()
            }
        }
    }

    nonisolated private static func motionHandler(_ owner: MotionSense) -> CMDeviceMotionHandler {
        { data, _ in
            guard let data else { return }
            let r = data.rotationRate, a = data.userAcceleration
            let sample = Sample(gx: data.gravity.x, gy: data.gravity.y, gz: data.gravity.z,
                                rotation: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
                                acceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
            Task { @MainActor in owner.add(sample) }
        }
    }

    private func add(_ sample: Sample) {
        samples.append(sample)
        if samples.count > 12 { samples.removeFirst(samples.count - 12) } // ~6 s window
        evaluate()
    }

    private func evaluate() {
        guard running, samples.count >= 6 else { return }
        let n = Double(samples.count)
        let gz = samples.map(\.gz).reduce(0, +) / n
        let rotation = samples.map(\.rotation).reduce(0, +) / n
        let acceleration = samples.map(\.acceleration).reduce(0, +) / n
        // Speeds go stale once you stop (the 50 m filter stops location updates), so trust them for a minute.
        let freshSpeed = Date().timeIntervalSince(speedAt) < 60 ? speed : nil
        let guess = Self.classify(transport: transport, speed: freshSpeed, gravityZ: gz,
                                  still: Self.isStill(rotation: rotation, acceleration: acceleration),
                                  hour: Calendar.current.component(.hour, from: Date()))
        if guess != candidate {
            candidate = guess
            candidateSince = Date()
            return
        }
        if guess != activity, Date().timeIntervalSince(candidateSince) >= Self.settleSeconds {
            activity = guess
            onChange?(guess)
        }
    }

    /// A phone on a table barely moves; one in a hand or pocket always trembles a little.
    nonisolated static func isStill(rotation: Double, acceleration: Double) -> Bool {
        rotation < 0.03 && acceleration < 0.02
    }

    /// gravityZ: -1 = flat face-up, +1 = flat face-down, ~-0.5 = held in front of you, > 0.35 = screen tilted toward the floor
    /// (held overhead while lying on your back).
    nonisolated static func classify(transport: Transport, speed: Double?, gravityZ: Double, still: Bool, hour: Int) -> PartnerActivity {
        let kmh = (speed ?? 0) * 3.6
        if kmh > 360 { return .flying } // faster than any high-speed train (Shinkansen/TGV top out ~320)
        switch transport {
        case .automotive:
            return kmh > 140 ? .train : .driving // shortcut: 40–140 km/h trains look like cars; no sensor separates them reliably
        case .cycling: return .cycling
        case .running: return .running
        case .walking: return .walking
        case .stationary, .unknown:
            if transport == .unknown, speed != nil { // no motion coprocessor (or no permission): fall back to GPS speed
                if kmh > 140 { return .train }
                if kmh > 25 { return .driving }
                if kmh > 12 { return .cycling }
                if kmh > 7 { return .running }
                if kmh > 2 { return .walking }
            }
            let night = hour >= 22 || hour < 7
            if still {
                if gravityZ > 0.9 { return .phoneDown }                          // face-down on a surface
                if gravityZ < -0.9 { return night ? .lyingDown : .phoneDown }     // flat, face-up: nightstand at night
                return .sitting                                                   // resting at an angle: pocket or stand
            }
            if gravityZ > 0.35 { return .lyingDown } // held above the face
            return gravityZ < -0.25 ? .onPhone : .sitting // screen tilted up at your face vs. upright in a pocket
        }
    }
}
