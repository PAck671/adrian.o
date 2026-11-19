import SwiftUI

struct PulseTab: View {
    @Environment(AppState.self) private var state
    @State private var showComposer = false
    @State private var reelStart: VideoClip?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HapticPad()
                patterns
                if !state.missedPulses.isEmpty { missedInbox }
                videoSection
            }
            .padding()
        }
        .background(Color.black)
        .fullScreenCover(isPresented: $showComposer) { VideoComposer() }
        .fullScreenCover(item: $reelStart) { ReelPlayer(startClip: $0) }
    }

    // MARK: Rhythm patterns

    private var patterns: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rhythms").font(.headline)
            HStack(spacing: 10) {
                ForEach([PulsePattern.heartbeat, .doubleSqueeze, .morseTap]) { pattern in
                    Button {
                        state.haptics.play(pattern)
                        state.sendPulse(pattern)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: pattern.symbol).font(.title2)
                            Text(pattern.label).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends a \(pattern.label) pulse to your partner")
                }
            }
        }
    }

    // MARK: Missed pulses

    private var missedInbox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Missed Pulses", systemImage: "tray.full.fill").font(.headline)
                Spacer()
                Button("Clear") { state.clearMissed() }.font(.subheadline)
            }
            ForEach(state.missedPulses) { pulse in
                HStack {
                    Image(systemName: pulse.pattern.symbol).foregroundStyle(.pink).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text("\(state.settings.partnerName) sent a \(pulse.pattern.label)").font(.subheadline)
                        Text(pulse.sentAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Feel it") { state.playMissed(pulse) }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .controlSize(.small)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 18).fill(.pink.opacity(0.12)))
    }

    // MARK: Video walkie-talkie

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Video Walkie-Talkie").font(.headline)
                Spacer()
                Button { showComposer = true } label: { Label("Record", systemImage: "video.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
            if state.clips.isEmpty {
                Text("No clips yet. Record up to 60 seconds; your partner watches whenever they're free.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(state.clips) { clip in
                            Button { reelStart = clip } label: { clipBubble(clip) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Text("Tap a bubble to play the reel from there.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func clipBubble(_ clip: VideoClip) -> some View {
        let mine = !state.isPartner(clip.senderId)
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(LinearGradient(colors: mine ? [.indigo, .purple] : [.pink, .orange],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 74, height: 74)
                    .overlay(Text(mine ? state.settings.myAvatar : state.settings.partnerAvatar).font(.system(size: 32)))
                    .overlay(Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).offset(y: 26))
                if let reaction = clip.reaction { Text(reaction).font(.title3) }
            }
            Text(clip.createdAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "Your" : "\(state.settings.partnerName)'s") clip, \(Int(clip.duration)) seconds")
    }
}

// MARK: - Haptic touchpad

struct HapticPad: View {
    @Environment(AppState.self) private var state
    @State private var ripples: [Ripple] = []
    @State private var touchDown = false
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var holdPoint = CGPoint.zero
    @State private var banner: String?

    struct Ripple: Identifiable {
        let id = UUID()
        let point: CGPoint
        let color: Color
        let scale: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [Color(hue: 0.93, saturation: 0.7, brightness: 0.38),
                                                  Color(hue: 0.76, saturation: 0.6, brightness: 0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(ripples) { RippleView(ripple: $0) }
                if holding {
                    Circle()
                        .fill(.pink.opacity(0.35))
                        .frame(width: 120, height: 120)
                        .position(holdPoint)
                        .phaseAnimator([0.8, 1.2]) { view, phase in view.scaleEffect(phase) }
                }
                VStack(spacing: 6) {
                    Image(systemName: holding ? "hand.raised.fill" : "hand.tap.fill").font(.largeTitle)
                    Text(banner ?? (holding ? "Holding… let go to send" : "Tap or hold to send a pulse"))
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !touchDown else { return }
                        touchDown = true
                        holdPoint = value.location
                        addRipple(at: value.location, color: .pink)
                        holdTask = Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            holding = true
                            state.haptics.beginHold()
                        }
                    }
                    .onEnded { value in
                        holdTask?.cancel()
                        if holding {
                            let duration = state.haptics.endHold()
                            holding = false
                            state.sendPulse(.hold, duration: duration)
                            addRipple(at: value.location, color: .pink, scale: 9)
                        } else {
                            state.haptics.play(.tap)
                            state.sendPulse(.tap)
                        }
                        touchDown = false
                    }
            )
            .onChange(of: state.lastIncomingPulse?.id) {
                guard let pulse = state.lastIncomingPulse else { return }
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                for i in 0..<3 {
                    Task {
                        try? await Task.sleep(for: .milliseconds(220 * i))
                        addRipple(at: center, color: .cyan, scale: 8)
                    }
                }
                showBanner("\(state.settings.partnerName) sent a \(pulse.pattern.label) 💓")
            }
        }
        .frame(height: 260)
        .accessibilityElement()
        .accessibilityLabel("Haptic touchpad")
        .accessibilityHint("Double-tap to send a tap pulse")
        .accessibilityAction { state.haptics.play(.tap); state.sendPulse(.tap) }
    }

    private func addRipple(at point: CGPoint, color: Color, scale: CGFloat = 6) {
        let ripple = Ripple(point: point, color: color, scale: scale)
        ripples.append(ripple)
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            ripples.removeAll { $0.id == ripple.id }
        }
    }

    private func showBanner(_ text: String) {
        banner = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if banner == text { banner = nil }
        }
    }
}

private struct RippleView: View {
    let ripple: HapticPad.Ripple
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(ripple.color, lineWidth: 3)
            .frame(width: 40, height: 40)
            .scaleEffect(expanded ? ripple.scale : 0.3)
            .opacity(expanded ? 0 : 1)
            .position(ripple.point)
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { expanded = true } }
            .allowsHitTesting(false)
    }
}
