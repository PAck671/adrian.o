import MapKit
import SwiftUI

struct MapTab: View {
    @Environment(AppState.self) private var state
    @Environment(\.isActiveTab) private var isActiveTab
    @State private var camera: MapCameraPosition = .automatic
    @State private var showPlaces = false
    @State private var partnerGlide = Glide()
    @State private var myGlide = Glide()
    @State private var glideUntil = Date.distantPast
    @State private var gliding = false
    @Namespace private var pillSpace

    var body: some View {
        let partner = state.partnerLocation
        let settings = state.settings
        ZStack {
            // Redraw at ~30 fps only while a pin is gliding between fixes; idle otherwise.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActiveTab || !gliding)) { context in
                let now = context.date
                let me = state.myCoordinate.map { myGlide.position(at: now) ?? $0 }
                let them = partner?.coordinate.map { partnerGlide.position(at: now) ?? $0 }
                Map(position: $camera) {
                    ForEach(state.savedPlaces) { place in
                        Annotation(place.name, coordinate: place.coordinate) {
                            Text(place.emoji).font(.title3).padding(4).background(Circle().fill(.black.opacity(0.6)))
                        }
                    }
                    if let me {
                        if settings.precision == .fuzzy {
                            MapCircle(center: me.fuzzed(), radius: 3000)
                                .foregroundStyle(.indigo.opacity(0.15))
                                .stroke(.indigo.opacity(0.6), lineWidth: 1)
                        }
                        Annotation(settings.myName, coordinate: me) {
                            AvatarPin(isMe: true, color: .indigo, dimmed: settings.precision == .ghost)
                        }
                    }
                    if let them {
                        if partner?.precision == .fuzzy {
                            MapCircle(center: them, radius: 3000)
                                .foregroundStyle(.tint.opacity(0.15))
                                .stroke(.tint.opacity(0.6), lineWidth: 1)
                        } else if let accuracy = partner?.accuracy, accuracy > 15 {
                            // Find My-style halo: how sure the GPS is about this spot.
                            MapCircle(center: them, radius: min(accuracy, 500))
                                .foregroundStyle(.tint.opacity(0.12))
                        }
                        Annotation(settings.partnerName, coordinate: them) {
                            AvatarPin(isMe: false, color: state.theme.accent,
                                      badge: partner?.placeLabel ?? partner?.activity.map { "\($0.emoji) \($0.label)" })
                        }
                        if let me {
                            MapPolyline(coordinates: [me, them], contourStyle: .geodesic)
                                .stroke(Color.redThread.opacity(0.9),
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
            }
            .onChange(of: partner?.updatedAt) {
                guard let p = state.partnerLocation?.coordinate else { return }
                startGlide(&partnerGlide, to: p)
            }
            .onChange(of: state.location.lastLocation) {
                guard let me = state.myCoordinate else { return }
                startGlide(&myGlide, to: me)
            }

            VStack {
                precisionPill
                Spacer()
                infoCard
            }
            .padding()
        }
        .sheet(isPresented: $showPlaces) { SavedPlacesSheet() }
    }

    private func startGlide(_ glide: inout Glide, to target: CLLocationCoordinate2D) {
        let now = Date()
        glide.retarget(to: target, now: now)
        let duration = glide.duration
        glideUntil = max(glideUntil, now.addingTimeInterval(duration + 0.1))
        gliding = true
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.15))
            if Date() >= glideUntil { gliding = false }
        }
    }

    // MARK: Privacy pill

    private var precisionPill: some View {
        HStack(spacing: 0) {
            ForEach(PrecisionMode.allCases) { mode in
                let selected = state.settings.precision == mode
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { state.setPrecision(mode) }
                } label: {
                    Label(mode.label, systemImage: mode.symbol)
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(color(for: mode)).matchedGeometryEffect(id: "precision", in: pillSpace)
                            }
                        }
                        .foregroundStyle(selected ? .black : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func color(for mode: PrecisionMode) -> Color {
        switch mode {
        case .live: .green
        case .fuzzy: .orange
        case .ghost: .gray
        }
    }

    // MARK: Info card

    private var infoCard: some View {
        let settings = state.settings
        let partner = state.partnerLocation
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let meters = state.distanceMeters {
                    Text(formatDistance(meters, miles: settings.useMiles)).font(.title.bold())
                    Text("apart").foregroundStyle(.secondary)
                } else {
                    Text("Distance unavailable").font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(settings.useMiles ? "mi" : "km") { state.settings.useMiles.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Switch to \(settings.useMiles ? "kilometers" : "miles")")
            }

            if let partner {
                HStack(spacing: 10) {
                    AvatarView(isMe: false, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(partner.locationOff == true ? "\(settings.partnerName) turned off location ⚠️"
                             : partner.precision == .ghost ? "\(settings.partnerName) is in Ghost Mode 👻"
                             : partner.placeLabel ?? partner.city ?? settings.partnerName)
                            .font(.subheadline.weight(.semibold))
                        if let activity = partner.activity, partner.precision != .ghost, partner.locationOff != true {
                            Text("\(activity.emoji) \(activity.label)"
                                 + (activity.isMoving && (partner.speed ?? 0) > 0.5 ? " · \(formatSpeed(partner.speed ?? 0, miles: settings.useMiles))" : ""))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .contentTransition(.opacity)
                                .animation(.easeInOut, value: activity)
                        }
                        HStack(spacing: 4) {
                            Text("Updated")
                            Text(partner.updatedAt, style: .relative)
                            Text("ago")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let battery = partner.battery {
                        Label("\(battery)%", systemImage: battery < 20 ? "battery.25" : "battery.75")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(battery < 20 ? .red.opacity(0.4) : .white.opacity(0.12)))
                    }
                }
            }

            HStack(spacing: 10) {
                AvatarView(isMe: true, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.location.placeName ?? (state.myCoordinate == nil ? "Your location is off" : "You"))
                        .font(.subheadline)
                    if let mine = state.motion.activity, settings.shareActivity {
                        Text("\(mine.emoji) \(mine.label.replacingOccurrences(of: "their", with: "your"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(settings.precision.label).font(.caption.weight(.bold)).foregroundStyle(color(for: settings.precision))
            }

            sharingControls

            HStack {
                Button { withAnimation(.easeInOut(duration: 0.8)) { camera = .automatic } } label: {
                    Label("Fit both", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Spacer()
                Button { Task { _ = await state.sendOnMyWay() } } label: { Label("On my way", systemImage: "car.fill") }
                    .disabled(state.myCoordinate == nil)
                Spacer()
                Button { showPlaces = true } label: { Label("Places", systemImage: "mappin.and.ellipse") }
            }
            .font(.subheadline)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private var sharingControls: some View {
        let location = state.location
        if location.isDenied {
            Text("Location access is off. Turn it on in Settings to share where you are.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if state.settings.precision != .ghost, !location.isUpdating {
            Button { state.setPrecision(state.settings.precision) } label: {
                Label("Start sharing my location", systemImage: "location.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else if location.canUpgradeToAlways {
            Button { location.requestAlways() } label: {
                Label("Keep sharing in the background (Allow Always)", systemImage: "location.fill.viewfinder")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct AvatarPin: View {
    let isMe: Bool
    let color: Color
    var badge: String?
    var dimmed = false

    var body: some View {
        VStack(spacing: 3) {
            if let badge {
                Text(badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color))
                    .foregroundStyle(.white)
            }
            AvatarView(isMe: isMe, size: 44)
                .overlay(Circle().stroke(color, lineWidth: 3))
                .opacity(dimmed ? 0.4 : 1)
        }
    }
}

// MARK: - Saved places

struct SavedPlacesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Home"
    @State private var emoji = "🏠"
    @State private var radius = 150.0

    private static let presets = [("Home", "🏠"), ("Campus", "🎓"), ("Work", "💼"), ("Gym", "🏋️")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.presets, id: \.0) { preset in
                                Button("\(preset.1) \(preset.0)") { name = preset.0; emoji = preset.1 }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    TextField("Name", text: $name)
                    TextField("Emoji", text: $emoji)
                    Picker("Radius", selection: $radius) {
                        Text("100 m").tag(100.0)
                        Text("150 m").tag(150.0)
                        Text("300 m").tag(300.0)
                    }
                    Button("Save my current location") {
                        guard let here = state.myCoordinate else { return }
                        state.savedPlaces.append(SavedPlace(name: name, emoji: emoji, lat: here.latitude,
                                                            lng: here.longitude, radius: radius))
                    }
                    .disabled(state.myCoordinate == nil || name.isEmpty)
                } header: { Text("Add a place") } footer: {
                    Text(state.myCoordinate == nil
                         ? "Start sharing on the Map tab first."
                         : "When you're inside a saved place in Live mode, your partner sees \"At \(name)\" instead of an address.")
                }

                Section("Your places") {
                    if state.savedPlaces.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(state.savedPlaces) { place in
                        HStack {
                            Text(place.emoji)
                            Text(place.name)
                            Spacer()
                            Text("\(Int(place.radius)) m").foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { state.savedPlaces.remove(atOffsets: $0) }
                }
            }
            .navigationTitle("Saved Places")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: - Smooth pin movement

/// Slides a pin from where it's drawn now to the newest fix over about one update interval, so it
/// moves like Find My instead of teleporting. Jumps over 2 km snap (e.g. reconnecting after a flight).
struct Glide {
    private var from: CLLocationCoordinate2D?
    private var to: CLLocationCoordinate2D?
    private var start = Date.distantPast
    private(set) var duration: TimeInterval = 0
    private var lastFix: Date?

    func position(at date: Date) -> CLLocationCoordinate2D? {
        guard let to else { return nil }
        guard let from, duration > 0 else { return to }
        let t = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        return CLLocationCoordinate2D(latitude: from.latitude + (to.latitude - from.latitude) * t,
                                      longitude: from.longitude + (to.longitude - from.longitude) * t)
    }

    mutating func retarget(to target: CLLocationCoordinate2D, now: Date) {
        let current = position(at: now)
        let interval = lastFix.map { now.timeIntervalSince($0) } ?? 0
        lastFix = now
        if let current, current.distance(to: target) < 2000 {
            from = current
            duration = min(max(interval, 0.4), 6) // glide for as long as the gap between fixes
        } else {
            from = nil
            duration = 0
        }
        to = target
        start = now
    }
}
