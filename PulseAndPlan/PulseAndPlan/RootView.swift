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
            if phase == .active { state.resumeSharingIfNeeded() }
            if phase == .background { state.didEnterBackground() }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PartnerHeader()
            TabView {
                PulseTab().tabItem { Label("Pulse", systemImage: "heart.circle.fill") }
                MapTab().tabItem { Label("Map", systemImage: "map.fill") }
                WatchTab().tabItem { Label("Watch", systemImage: "popcorn.fill") }
                PlayTab().tabItem { Label("Play", systemImage: "gamecontroller.fill") }
                PlanTab().tabItem { Label("Plan", systemImage: "calendar") }
            }
            .tint(.pink)
        }
        .background(Color.black)
        .overlay {
            if let movie = state.match {
                MatchOverlay(movie: movie) { state.match = nil }
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
                Text(s.partnerAvatar)
                    .font(.system(size: 28))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(0.08)))
                Circle()
                    .fill(state.partnerOnline ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.black, lineWidth: 2))
            }
            .accessibilityLabel("\(s.partnerName) is \(state.partnerOnline ? "online" : "offline")")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.partnerName).font(.headline)
                    if s.mode == .demo {
                        Text("DEMO")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(.purple.opacity(0.45)))
                    }
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
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let label = partnerStatus {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.pink)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.haptics.play(.heartbeat)
                state.sendPulse(.heartbeat)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                    .symbolEffect(.bounce, value: state.lastIncomingPulse?.id)
            }
            .accessibilityLabel("Send a heartbeat")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var partnerStatus: String? {
        guard let loc = state.partnerLocation else { return nil }
        if loc.precision == .ghost { return "👻 Ghost mode" }
        return loc.placeLabel ?? loc.city
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
                    Picker("Mode", selection: $state.settings.mode) {
                        ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !state.syncStatus.isEmpty {
                        Text(state.syncStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Sync mode") }

                if state.settings.mode == .demo {
                    Section {
                        Picker("Partner city", selection: $state.settings.demoCity) {
                            ForEach(DemoCity.all) { Text($0.name).tag($0.name) }
                        }
                    } header: { Text("Demo partner") } footer: {
                        Text("Simulates a connected partner: a moving pin, pulse replies, movie matches and video replies.")
                    }
                } else {
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
                    } header: { Text("Live pair") } footer: {
                        Text("One of you creates a code and shares it; the other joins with it.")
                    }
                }

                Section("You two") {
                    TextField("Your name", text: $state.settings.myName)
                    TextField("Your avatar emoji", text: $state.settings.myAvatar)
                    TextField("Partner's name", text: $state.settings.partnerName)
                    TextField("Partner's avatar emoji", text: $state.settings.partnerAvatar)
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
                } header: { Text("Location") }

                Section {
                    SecureField("TMDB API key (optional)", text: $state.settings.tmdbKey)
                    Button(loadingTMDB ? "Loading…" : "Load trending titles") { loadTMDB() }
                        .disabled(state.settings.tmdbKey.isEmpty || loadingTMDB)
                    if !tmdbMessage.isEmpty { Text(tmdbMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Movies") } footer: {
                    Text("The built-in catalog works without a key. A key adds this week's trending titles with posters.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: state.settings.demoCity) { _, city in
                state.settings.partnerTimeZone = DemoCity.named(city).timeZone
            }
        }
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
                let movies = try await TMDB.trending(apiKey: state.settings.tmdbKey)
                state.extraMovies = movies
                tmdbMessage = "Added \(movies.count) trending titles to your deck."
            } catch {
                tmdbMessage = "Couldn't load from TMDB: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Match overlay

struct MatchOverlay: View {
    let movie: Movie
    let dismiss: () -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea().onTapGesture(perform: dismiss)
            ForEach(0..<20, id: \.self) { i in
                let angle = Double(i) / 20 * 2 * .pi
                Text(["🎉", "❤️", "🍿", "✨"][i % 4])
                    .font(.largeTitle)
                    .offset(x: appear ? cos(angle) * 170 : 0, y: appear ? sin(angle) * 300 : 0)
                    .opacity(appear ? 0 : 1)
                    .animation(.easeOut(duration: 1.4), value: appear)
            }
            VStack(spacing: 16) {
                Text("It's a Match!")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                PosterView(movie: movie).frame(width: 180, height: 260)
                Text("You both want to watch \(movie.title). Added to Tonight's Queue.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                Button("Yay!", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
            .scaleEffect(appear ? 1 : 0.6)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: appear)
        }
        .onAppear { appear = true }
    }
}
