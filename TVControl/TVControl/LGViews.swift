import AVKit
import SwiftUI

struct AppsTab: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        if tv.target == .lg { LGAppsView() } else { GoogleAppsView() }
    }
}

struct CastTab: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        if tv.target == .lg { LGCastView() } else { GoogleCastView() }
    }
}

struct AppTile: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            Text(String(name.prefix(1)))
                .font(.title2.weight(.bold))
                .frame(width: 46, height: 46)
                .background(Color(white: 0.22), in: Circle())
            Text(name)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LGAppsView: View {
    @EnvironmentObject private var tv: TVController
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tv.lgApps.isEmpty && tv.lgInputs.isEmpty {
                        Text("Your LG TV's apps and inputs appear here once it's connected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    if !tv.lgInputs.isEmpty {
                        Text("Inputs").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tv.lgInputs) { input in
                                    Button { tv.switchInput(input.id) } label: {
                                        Text(input.id == LGCommands.googleTVInput ? "Google TV" : input.name)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 16)
                                            .frame(minHeight: 44)
                                            .background(surface, in: Capsule())
                                            .opacity(input.connected ? 1 : 0.55)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !tv.lgApps.isEmpty {
                        Text("Apps").font(.headline)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(tv.lgApps) { app in
                                Button { tv.launchLG(app) } label: { AppTile(name: app.name) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await tv.refreshLG() }
        }
    }
}

struct LGCastView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Cast to LG TV").font(.title2.weight(.bold))
                HStack(spacing: 14) {
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Choose AirPlay device")
                    Text("Send this iPhone's video or audio with AirPlay")
                    Spacer()
                }
                .padding(16)
                .background(surface, in: RoundedRectangle(cornerRadius: 14))
                Text("To mirror your whole screen, open Control Center, tap Screen Mirroring, and choose [LG] webOS TV UN6950ZUF.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
