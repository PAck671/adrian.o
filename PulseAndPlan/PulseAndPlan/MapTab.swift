import MapKit
import SwiftUI

struct MapTab: View {
    @Environment(AppState.self) private var state
    @State private var camera: MapCameraPosition = .automatic
    @State private var showPlaces = false

    var body: some View {
        let partner = state.partnerLocation
        let settings = state.settings
        ZStack {
            Map(position: $camera) {
                ForEach(state.savedPlaces) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Text(place.emoji).font(.title3).padding(4).background(Circle().fill(.black.opacity(0.6)))
                    }
                }
                if let me = state.myCoordinate {
                    if settings.precision == .fuzzy {
                        MapCircle(center: me.fuzzed(), radius: 3000)
                            .foregroundStyle(.indigo.opacity(0.15))
                            .stroke(.indigo.opacity(0.6), lineWidth: 1)
                    }
                    Annotation(settings.myName, coordinate: me) {
                        AvatarPin(emoji: settings.myAvatar, color: .indigo, dimmed: settings.precision == .ghost)
                    }
                }
                if let p = partner?.coordinate {
                    if partner?.precision == .fuzzy {
                        MapCircle(center: p, radius: 3000)
                            .foregroundStyle(.pink.opacity(0.15))
                            .stroke(.pink.opacity(0.6), lineWidth: 1)
                    }
                    Annotation(settings.partnerName, coordinate: p) {
                        AvatarPin(emoji: settings.partnerAvatar, color: .pink, badge: partner?.placeLabel)
                    }
                    if let me = state.myCoordinate {
                        MapPolyline(coordinates: [me, p], contourStyle: .geodesic)
                            .stroke(LinearGradient(colors: [.indigo, .pink], startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapCompass()
                MapScaleView()
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

    // MARK: Privacy pill

    private var precisionPill: some View {
        HStack(spacing: 0) {
            ForEach(PrecisionMode.allCases) { mode in
                let selected = state.settings.precision == mode
                Button { state.setPrecision(mode) } label: {
                    Label(mode.label, systemImage: mode.symbol)
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(selected ? color(for: mode) : .clear, in: Capsule())
                        .foregroundStyle(selected ? .black : .primary)
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
                    Text(settings.partnerAvatar).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(partner.precision == .ghost ? "\(settings.partnerName) is in Ghost Mode 👻"
                                                         : partner.placeLabel ?? partner.city ?? settings.partnerName)
                            .font(.subheadline.weight(.semibold))
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
                Text(settings.myAvatar).font(.title2)
                Text(state.location.placeName ?? (state.myCoordinate == nil ? "Your location is off" : "You"))
                    .font(.subheadline)
                Spacer()
                Text(settings.precision.label).font(.caption.weight(.bold)).foregroundStyle(color(for: settings.precision))
            }

            sharingControls

            HStack {
                Button { camera = .automatic } label: { Label("Fit both", systemImage: "arrow.up.left.and.arrow.down.right") }
                Spacer()
                Button { showPlaces = true } label: { Label("Saved places", systemImage: "mappin.and.ellipse") }
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
            .tint(.pink)
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
    let emoji: String
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
            Text(emoji)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black))
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
