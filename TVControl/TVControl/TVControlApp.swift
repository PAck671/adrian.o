import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

let surface = Color(white: 0.12)
private typealias Key = TVCommands.Key

@main
struct TVControlApp: App {
    @StateObject private var tv = TVController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tv)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var tv: TVController
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            RemoteTab().tabItem { Label("Remote", systemImage: "av.remote") }
            AppsTab().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            CastTab().tabItem { Label("Cast", systemImage: "play.tv") }
            TVTab().tabItem { Label("TV", systemImage: "slider.horizontal.3") }
            HomeTab().tabItem { Label("Home", systemImage: "video.fill") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("TV", selection: $tv.target) {
                    ForEach(TVController.Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                ConnectionBanner()
            }
            .background(Color.black)
        }
        .task { await tv.connectActive() }
        .onChange(of: tv.target) { _, _ in Task { await tv.connectActive() } }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active { Task { await tv.connectActive() } }
        }
        .alert("TV Control", isPresented: Binding(get: { tv.notice != nil }, set: { if !$0 { tv.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tv.notice ?? "")
        }
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        switch tv.activeLink {
        case .connected:
            EmptyView()
        case .idle, .connecting:
            banner("Connecting to your \(tv.target.rawValue)…", retry: false)
        case .approve:
            banner(tv.target == .lg ? "On your LG TV, choose Accept for LG Remote App." : "On your TV, check Always allow, then choose Allow.", retry: false)
        case .failed(let message):
            banner(message, retry: true)
        }
    }

    private func banner(_ text: String, retry: Bool) -> some View {
        HStack(spacing: 12) {
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if retry {
                Button("Retry") { Task { await tv.connectActive() } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(surface)
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 60
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: size, height: size)
                .background(surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct KeyButton: View {
    @EnvironmentObject private var tv: TVController
    let symbol: String
    let label: String
    let code: Int

    var body: some View {
        RoundButton(symbol: symbol, label: label) { tv.press(code) }
    }
}

struct DPad: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        ZStack {
            Circle().fill(surface)
            VStack(spacing: 0) {
                arrow("chevron.up", "Up", Key.up)
                HStack(spacing: 0) {
                    arrow("chevron.left", "Left", Key.left)
                    Button { tv.press(Key.ok) } label: {
                        Text("OK")
                            .font(.headline)
                            .frame(width: 92, height: 92)
                            .background(Color(white: 0.22), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("OK")
                    arrow("chevron.right", "Right", Key.right)
                }
                arrow("chevron.down", "Down", Key.down)
            }
        }
        .frame(width: 276, height: 276)
    }

    private func arrow(_ symbol: String, _ label: String, _ code: Int) -> some View {
        Button { tv.press(code) } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 92, height: 92)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct RemoteTab: View {
    @EnvironmentObject private var tv: TVController
    @StateObject private var voice = VoiceInput()
    @State private var text = ""
    @State private var showVoice = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        KeyButton(symbol: "power", label: "Power", code: Key.power)
                        Spacer()
                        if tv.target == .lg {
                            RoundButton(symbol: "tv.and.mediabox", label: "Switch to Google TV") { tv.switchInput(LGCommands.googleTVInput) }
                            Spacer()
                            RoundButton(symbol: "gearshape.fill", label: "LG settings") { tv.lgButton("MENU") }
                        } else {
                            RoundButton(symbol: "square.grid.3x3.fill", label: "Quick panel") { tv.send(TVCommands.quickPanel) }
                            Spacer()
                            RoundButton(symbol: "mic.fill", label: "Voice search") { showVoice = true }
                        }
                    }
                    DPad()
                    HStack {
                        KeyButton(symbol: "arrow.uturn.backward", label: "Back", code: Key.back)
                        Spacer()
                        KeyButton(symbol: "house.fill", label: "Home", code: Key.home)
                        Spacer()
                        KeyButton(symbol: "speaker.slash.fill", label: "Mute", code: Key.mute)
                    }
                    HStack {
                        KeyButton(symbol: "backward.fill", label: "Rewind", code: Key.rewind)
                        Spacer()
                        KeyButton(symbol: "playpause.fill", label: "Play or pause", code: Key.playPause)
                        Spacer()
                        KeyButton(symbol: "forward.fill", label: "Fast forward", code: Key.forward)
                    }
                    HStack {
                        KeyButton(symbol: "speaker.minus.fill", label: "Volume down", code: Key.volumeDown)
                        Spacer()
                        Text("Volume").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        KeyButton(symbol: "speaker.plus.fill", label: "Volume up", code: Key.volumeUp)
                    }
                    HStack(spacing: 8) {
                        TextField("Type on TV", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .onSubmit(sendText)
                            .padding(12)
                            .background(surface, in: RoundedRectangle(cornerRadius: 12))
                        Button("Send", action: sendText).disabled(text.isEmpty)
                        if tv.target == .google {
                            Button("Search") {
                                tv.search(text)
                                text = ""
                            }
                            .disabled(text.isEmpty)
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showVoice) {
            VoiceSheet(voice: voice).presentationDetents([.fraction(0.38)])
        }
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        tv.type(text)
        text = ""
    }
}

struct VoiceSheet: View {
    @EnvironmentObject private var tv: TVController
    @ObservedObject var voice: VoiceInput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: voice.isListening ? "waveform" : "mic.fill").font(.largeTitle)
            Text(voice.problem ?? (voice.text.isEmpty ? "Say what you want to watch" : voice.text))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Search on TV") {
                    tv.search(voice.text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .disabled(voice.text.isEmpty)
            }
        }
        .padding(24)
        .task { await voice.start() }
        .onDisappear { voice.stop() }
    }
}

struct GoogleAppsView: View {
    @EnvironmentObject private var tv: TVController
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                if tv.apps.isEmpty {
                    Text("Your TV's apps appear here once it's connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(tv.apps) { app in
                        Button { tv.launch(app) } label: { AppTile(name: app.name) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .refreshable { await tv.refreshApps() }
        }
    }
}

struct GoogleCastView: View {
    @EnvironmentObject private var tv: TVController
    @State private var link = ""
    @State private var picked: PhotosPickerItem?
    @State private var importing = false
    @State private var volume = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cast to TV").font(.title2.weight(.bold))

                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos])) {
                        row("photo.on.rectangle", "Photos and videos")
                    }
                    .buttonStyle(.plain)
                    .disabled(tv.isPreparing)

                    Button { importing = true } label: { row("folder", "Files and music") }
                        .buttonStyle(.plain)
                        .disabled(tv.isPreparing)

                    HStack(spacing: 8) {
                        TextField("YouTube, Netflix or media link", text: $link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(surface, in: RoundedRectangle(cornerRadius: 12))
                        Button("Cast") {
                            let current = link
                            Task { await tv.castLink(current) }
                        }
                        .disabled(link.isEmpty)
                    }

                    if !tv.castStatus.isEmpty {
                        Text(tv.castStatus).font(.subheadline).foregroundStyle(.secondary)
                    }

                    if tv.isCasting {
                        HStack {
                            RoundButton(symbol: "gobackward.10", label: "Back 10 seconds") { tv.castSeek(-10) }
                            Spacer()
                            RoundButton(symbol: tv.castStatus == "Paused" ? "play.fill" : "pause.fill", label: "Play or pause") {
                                tv.castPlayPause()
                            }
                            Spacer()
                            RoundButton(symbol: "goforward.10", label: "Forward 10 seconds") { tv.castSeek(10) }
                            Spacer()
                            RoundButton(symbol: "stop.fill", label: "Stop casting") { tv.stopCast() }
                        }
                        HStack {
                            Image(systemName: "speaker.fill").accessibilityHidden(true)
                            Slider(value: $volume, in: 0...1) { editing in
                                if !editing { tv.castVolume(volume) }
                            }
                            .accessibilityLabel("Cast volume")
                        }
                        Text("Keep this app open while a photo, video or song from your phone is on the TV.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                await tv.castPicked(item)
                picked = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .audio]) { result in
            if case .success(let url) = result {
                Task { await tv.castImported(url) }
            }
        }
    }

    private func row(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).frame(width: 26)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

struct TVTab: View {
    @EnvironmentObject private var tv: TVController
    @State private var address = ""
    @State private var confirmRestart = false

    var body: some View {
        NavigationStack {
            List {
                if tv.target == .lg {
                    Section("LG TV") {
                        action("Switch to Google TV", "tv.and.mediabox") { tv.switchInput(LGCommands.googleTVInput) }
                        action("Turn on through Google TV box", "power") { tv.wakeLG() }
                        action("LG settings", "gearshape") { tv.lgButton("MENU") }
                    }
                } else {
                    Section("Google TV") {
                        action("Home controls and profiles", "house.and.flag") { tv.send(TVCommands.quickPanel) }
                        action("Movie and TV library", "film.stack") { tv.send(TVCommands.library) }
                        action("TV settings and ambient mode", "gearshape") { tv.send(TVCommands.settings) }
                        action("Fix audio sync", "waveform") { tv.send(TVCommands.syncTuner) }
                    }
                }
                Section("Connection") {
                    TextField("TV Wi-Fi address", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("Save address") { tv.updateHost(address) }
                }
                Section {
                    if tv.target == .lg {
                        Button("Forget LG pairing", role: .destructive) { tv.forgetLG() }
                    } else {
                        Button("Restart TV", role: .destructive) { confirmRestart = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(tv.target.rawValue)
        }
        .onAppear { address = tv.activeHost }
        .onChange(of: tv.target) { _, _ in address = tv.activeHost }
        .confirmationDialog("Restart your TV?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart TV", role: .destructive) { tv.restart() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func action(_ title: String, _ symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: symbol) }
    }
}
