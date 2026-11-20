import PhotosUI
import SwiftUI

@main
struct PulseAndPlanApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
                .onAppear { state.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // .inactive (Control Center, app switcher peek) is transient; only flip on real transitions.
            if phase == .active { state.setActive(true) }
            if phase == .background { state.setActive(false) }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var tab: AppTab = .pulse
    @State private var showSplash = true

    var body: some View {
        @Bindable var state = state
        ZStack {
            ThemedBackground()
            VStack(spacing: 0) {
                PartnerHeader()
                ZStack {
                    // Every tab stays alive (games, map position, half-written notes) and cross-fades in.
                    ForEach(AppTab.allCases) { item in
                        let active = item == tab
                        content(for: item)
                            .environment(\.isActiveTab, active)
                            .opacity(active ? 1 : 0)
                            .scaleEffect(active ? 1 : 0.95)
                            .offset(y: active ? 0 : 16)
                            .blur(radius: active ? 0 : 6)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                    }
                }
                .frame(maxHeight: .infinity)
                TabBar(selection: $tab)
            }
            if let toast = state.toast {
                VStack {
                    ToastView(text: toast)
                    Spacer()
                }
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(5)
            }
            if let movie = state.match {
                MatchOverlay(movie: movie) { state.match = nil }
                    .transition(.opacity)
                    .zIndex(6)
            }
            if showSplash {
                SplashView()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 1.3))))
                    .zIndex(10)
            }
        }
        .tint(state.theme.accent)
        .environment(\.surfaceStyle, state.theme.surface)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.toast)
        .animation(.easeInOut(duration: 0.3), value: state.match)
        .sheet(item: $state.messageDraft) { MessageSheet(draft: $0, phone: state.settings.partnerPhone) }
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.6)) { showSplash = false }
        }
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .pulse: PulseTab()
        case .map: MapTab()
        case .watch: WatchTab()
        case .play: PlayTab()
        case .plan: PlanTab()
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .surface(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.tint.opacity(0.5)))
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Profile photos

/// Profile photo, or the emoji when there isn't one.
struct AvatarView: View {
    @Environment(AppState.self) private var state
    let isMe: Bool
    var size: CGFloat = 44

    var body: some View {
        let photo = isMe ? state.myPhoto : state.partnerPhoto
        ZStack {
            Circle().fill(.ultraThinMaterial)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Text(isMe ? state.settings.myAvatar : state.settings.partnerAvatar).font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(isMe ? "Your photo" : "\(state.settings.partnerName)'s photo")
    }
}

struct PhotoRow: View {
    @Environment(AppState.self) private var state
    let isMe: Bool
    @State private var item: PhotosPickerItem?

    var body: some View {
        let hasPhoto = (isMe ? state.myPhoto : state.partnerPhoto) != nil
        HStack(spacing: 14) {
            AvatarView(isMe: isMe, size: 52)
            PhotosPicker(selection: $item, matching: .images) {
                Text(hasPhoto ? "Change \(isMe ? "your" : "partner's") photo" : "Add \(isMe ? "your" : "partner's") photo")
            }
            Spacer()
            if hasPhoto {
                Button(role: .destructive) { state.removePhoto(me: isMe) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove photo")
            }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) { state.setPhoto(data, me: isMe) }
                item = nil
            }
        }
    }
}

// MARK: - Persistent partner header

struct PartnerHeader: View {
    @Environment(AppState.self) private var state
    @State private var showSettings = false

    var body: some View {
        let s = state.settings
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(isMe: false, size: 46)
                    .overlay(Circle().stroke(.tint.opacity(0.6), lineWidth: 2))
                Circle()
                    .fill(state.partnerOnline ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.black, lineWidth: 2))
            }
            .accessibilityLabel("\(s.partnerName) is \(state.partnerOnline ? "online" : "offline")")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button { showSettings = true } label: { Text(s.partnerName).font(.headline) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens Settings to change names")
                }
                HStack(spacing: 10) {
                    TimelineView(.everyMinute) { context in
                        Label(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: state.partnerTZ)),
                              systemImage: "clock")
                    }
                    if let meters = state.distanceMeters {
                        Label(formatDistance(meters, miles: s.useMiles), systemImage: "location")
                    }
                    if let battery = state.partnerLocation?.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .foregroundStyle(battery <= 15 ? .red : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let label = partnerStatus {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.haptics.play(.heartbeat)
                state.sendPulse(.heartbeat)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .shadow(color: state.theme.accent.opacity(0.7), radius: 8) // glows on true black
                    .symbolEffect(.bounce, value: state.lastIncomingPulse?.id)
            }
            .accessibilityLabel("Send a heartbeat")
            Menu {
                Button { Task { _ = await state.sendOnMyWay() } } label: { Label("I'm on my way", systemImage: "car.fill") }
                Button {
                    Task { state.textPartner(await state.sendOnMyWay() + " 🚗") }
                } label: { Label("On my way + iMessage", systemImage: "message.fill") }
                Button { state.textPartner("Thinking of you 💕") } label: { Label("Text \(s.partnerName)", systemImage: "bubble.left.and.text.bubble.right.fill") }
            } label: {
                Image(systemName: "paperplane.fill").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Quick messages")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .surface(Rectangle())
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var partnerStatus: String? {
        guard let loc = state.partnerLocation else { return nil }
        if loc.locationOff == true { return "⚠️ Location off" }
        if loc.precision == .ghost { return "👻 Ghost mode" }
        let place = loc.placeLabel ?? loc.city
        guard let activity = loc.activity else { return place }
        let doing = "\(activity.emoji) \(activity.label)" + (activity.isMoving && (loc.speed ?? 0) > 0.5
            ? " · \(formatSpeed(loc.speed ?? 0, miles: state.settings.useMiles))" : "")
        return [place, doing].compactMap { $0 }.joined(separator: " · ")
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 88...: "battery.100"
        case 63..<88: "battery.75"
        case 38..<63: "battery.50"
        case 13..<38: "battery.25"
        default: "battery.0"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var joinCode = ""
    @State private var tmdbMessage = ""
    @State private var loadingTMDB = false

    var body: some View {
        @Bindable var state = state
        NavigationStack {
            Form {
                Section {
                    NavigationLink { AppearanceView() } label: {
                        Label("Theme & background", systemImage: "paintpalette.fill")
                    }
                }

                    Section {
                        if !Config.isSupabaseConfigured {
                            Label("Add SUPABASE_URL and SUPABASE_ANON_KEY in Config.swift, then rebuild.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        LabeledContent("Couple code", value: state.settings.coupleCode.isEmpty ? "—" : state.settings.coupleCode)
                            .textSelection(.enabled)
                        Button("Create a new code") { state.settings.coupleCode = RoomCode.make(length: 6, digits: true) }
                        HStack {
                            TextField("Partner's 6-character code", text: $joinCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Button("Join") { state.settings.coupleCode = joinCode.uppercased() }
                                .disabled(joinCode.count != 6)
                        }
                        if !state.settings.coupleCode.isEmpty {
                            Button("Send code via iMessage") {
                                state.textPartner("Join me on Red Thread 💕 Our couple code: \(state.settings.coupleCode)")
                            }
                        }
                        if !state.syncStatus.isEmpty {
                            Text(state.syncStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Pair with your partner") } footer: {
                        Text("One of you creates a code and shares it; the other joins with it.")
                    }

                Section {
                    PhotoRow(isMe: true)
                    TextField("Your name", text: $state.settings.myName)
                    TextField("Your emoji (shown without a photo)", text: $state.settings.myAvatar)
                    PhotoRow(isMe: false)
                    TextField("Partner's name", text: $state.settings.partnerName)
                    TextField("Partner's emoji", text: $state.settings.partnerAvatar)
                    TextField("Partner's phone or iMessage email", text: $state.settings.partnerPhone)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("You two") } footer: {
                    Text("Your photo syncs to your partner in Live Pair mode. A partner photo you pick here stays on this phone until they set their own.")
                }

                Section {
                    Toggle("Pulses while I'm away", isOn: $state.settings.alertPulses)
                    Toggle("Low battery (15% and 5%)", isOn: $state.settings.alertBattery)
                    Toggle("Arrives at a saved place", isOn: $state.settings.alertArrivals)
                    Toggle("Gets within 1 km", isOn: $state.settings.alertNearby)
                    Toggle("Goes Ghost or turns off location", isOn: $state.settings.alertPrivacy)
                    Toggle("Stay connected in background", isOn: $state.settings.stayConnected)
                    Button("Send test alerts") { state.sendTestAlerts() }
                } header: { Text("Alerts about \(state.settings.partnerName)") } footer: {
                    Text("iOS only lets this app run in the background while it shares your location, and never plays custom vibrations in the background, so away pulses arrive as a notification and wait in Missed Pulses. \"Stay connected\" keeps location running even when you sit still (uses more battery). Installed through LiveContainer, iOS uses LiveContainer's own permissions, so background alerts need a standalone install (Sideloadly or AltStore).")
                }

                Section("Time zones") {
                    Picker("My time zone", selection: $state.settings.myTimeZone) { timeZoneOptions }
                        .pickerStyle(.navigationLink)
                    Picker("Partner's time zone", selection: $state.settings.partnerTimeZone) { timeZoneOptions }
                        .pickerStyle(.navigationLink)
                }

                Section("Units") {
                    Toggle("Show distance in miles", isOn: $state.settings.useMiles)
                }

                Section {
                    LabeledContent("Permission", value: authorizationText)
                    if state.location.canUpgradeToAlways {
                        Button("Allow Always for background sharing") { state.location.requestAlways() }
                    }
                    if state.location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open iOS Settings") { openURL(url) }
                    }
                    Toggle("Share what I'm doing", isOn: $state.settings.shareActivity)
                    if let mine = state.motion.activity {
                        LabeledContent("Right now", value: "\(mine.emoji) \(mine.label.replacingOccurrences(of: "their", with: "your"))")
                    }
                } header: { Text("Location") } footer: {
                    Text("Uses the motion coprocessor, gyroscope and accelerometer to guess sitting, lying down, on your phone, walking, cycling, in a car, on a train or flying. Your partner sees the guess, never raw sensor data. Ghost mode shares nothing, and your partner is told when you go Ghost or switch Location Services off.")
                }

                Section {
                    ServicePicker(selection: $state.settings.services)
                    SecureField("TMDB API key (free at themoviedb.org)", text: $state.settings.tmdbKey)
                    Button(loadingTMDB ? "Loading…" : "Load titles from our services") { loadTMDB() }
                        .disabled(state.settings.tmdbKey.isEmpty || loadingTMDB)
                    if !tmdbMessage.isEmpty { Text(tmdbMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Movies & streaming") } footer: {
                    Text("Netflix, HBO Max, Disney+, Hulu and YouTube don't offer apps a way to read your watch history, so pick the services you have: the Watch deck shows what's on them (availability from TMDB/JustWatch) and each card opens the title in that app.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black.opacity(0.4))
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .sheetSurface()
    }

    private var timeZoneOptions: some View {
        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
    }

    private var authorizationText: String {
        switch state.location.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
        case .denied: "Denied"
        case .restricted: "Restricted"
        default: "Not asked yet"
        }
    }

    private func loadTMDB() {
        loadingTMDB = true
        Task {
            defer { loadingTMDB = false }
            do {
                let services = state.settings.services.compactMap(StreamingService.init(rawValue:))
                let movies = services.isEmpty
                    ? try await TMDB.trending(apiKey: state.settings.tmdbKey)
                    : try await TMDB.onServices(services, apiKey: state.settings.tmdbKey)
                state.extraMovies = movies
                tmdbMessage = "Added \(movies.count) titles to your deck."
            } catch {
                tmdbMessage = "Couldn't load from TMDB: \(error.localizedDescription)"
            }
        }
    }
}

struct ServicePicker: View {
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(StreamingService.allCases) { service in
                let on = selection.contains(service.rawValue)
                Button {
                    if on { selection.removeAll { $0 == service.rawValue } } else { selection.append(service.rawValue) }
                } label: {
                    Text(service.label)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1))))
                        .foregroundStyle(on ? .black : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Appearance

struct AppearanceView: View {
    @Environment(AppState.self) private var state
    @State private var photoItem: PhotosPickerItem?

    static var glassAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Theme") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ThemePreset.allCases) { preset in
                            let selected = state.theme.preset == preset && state.theme.customAccent == nil
                            Button {
                                withAnimation(.spring) {
                                    state.theme.preset = preset
                                    state.theme.customAccent = nil
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(LinearGradient(colors: preset.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 54, height: 54)
                                        .overlay(Circle().fill(preset.accent).frame(width: 18, height: 18))
                                        .overlay(Circle().stroke(selected ? Color.white : .clear, lineWidth: 3))
                                    Text(preset.label).font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(preset.label) theme")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                ColorPicker("Custom accent color", selection: Binding(
                    get: { state.theme.accent },
                    set: { state.theme.customAccent = RGBA($0) }
                ), supportsOpacity: false)
            }

            Section {
                Toggle(isOn: $state.theme.glass.animation(.spring)) {
                    Label("Liquid Glass", systemImage: "drop.halffull")
                }
                .disabled(!Self.glassAvailable)
            } header: { Text("Surfaces") } footer: {
                Text(Self.glassAvailable
                     ? "Cards, bars and sheets become see-through glass that refracts your background. Looks best over Aurora or your own photo."
                     : "Liquid Glass needs iOS 26 or later.")
            }

            Section {
                Picker("Effect", selection: $state.theme.effect) {
                    ForEach(BackgroundEffect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                let photoLabel = state.backgroundImage == nil ? "Choose a photo" : "Change photo"
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(photoLabel, systemImage: "photo.on.rectangle")
                }
                if state.theme.effect == .photo {
                    VStack(alignment: .leading) {
                        Text("Dim").font(.caption)
                        Slider(value: $state.theme.photoDim, in: 0...0.85)
                        Text("Blur").font(.caption)
                        Slider(value: $state.theme.photoBlur, in: 0...20)
                    }
                }
            } header: { Text("Background") }
        }
        .scrollContentBackground(.hidden)
        .background(ThemedBackground().opacity(0.9))
        .navigationTitle("Theme & background")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { state.setBackgroundPhoto(data) }
                photoItem = nil
            }
        }
    }
}

// MARK: - Match overlay

struct MatchOverlay: View {
    @Environment(AppState.self) private var state
    let movie: Movie
    let dismiss: () -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea().onTapGesture(perform: dismiss)
            ForEach(0..<24, id: \.self) { i in
                let angle = Double(i) / 24 * 2 * .pi
                Text(["🎉", "❤️", "🍿", "✨"][i % 4])
                    .font(.largeTitle)
                    .rotationEffect(.degrees(appear ? Double(i * 40) : 0))
                    .offset(x: appear ? cos(angle) * 180 : 0, y: appear ? sin(angle) * 320 : 0)
                    .opacity(appear ? 0 : 1)
                    .animation(.easeOut(duration: 1.5), value: appear)
            }
            VStack(spacing: 16) {
                Text("It's a Match!")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [state.theme.accent, .orange], startPoint: .leading, endPoint: .trailing))
                PosterView(movie: movie)
                    .frame(width: 180, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .rotation3DEffect(.degrees(appear ? 0 : 90), axis: (x: 0, y: 1, z: 0))
                Text("You both want to watch \(movie.title). Added to Tonight's Queue.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                HStack {
                    Button("Text \(state.settings.partnerName)") {
                        state.textPartner("It's a match! 🍿 Watch \(movie.title) together tonight?")
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Button("Yay!", action: dismiss).buttonStyle(.borderedProminent)
                }
            }
            .scaleEffect(appear ? 1 : 0.6)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: appear)
        }
        .onAppear { appear = true }
    }
}
