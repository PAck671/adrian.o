import SwiftUI

struct WatchTab: View {
    @Environment(AppState.self) private var state
    @State private var section = 0
    @AppStorage("onlyOurServices") private var onlyOurs = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Section", selection: $section.animation(.spring)) {
                Text("Swipe").tag(0)
                Text("Tonight's Queue (\(state.queue.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            if section == 0, !state.settings.services.isEmpty {
                Toggle(isOn: $onlyOurs.animation(.spring)) {
                    Label("Only on our services", systemImage: "tv.and.mediabox")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 24)
            }
            Group {
                if section == 0 { SwipeDeck() } else { QueueList() }
            }
            .transition(.asymmetric(insertion: .move(edge: section == 0 ? .leading : .trailing).combined(with: .opacity),
                                    removal: .opacity))
        }
        .padding(.top)
    }
}

/// Catalog tags for the services you picked in Settings.
@MainActor
func ourServiceTags(_ state: AppState) -> Set<String> {
    Set(state.settings.services.compactMap(StreamingService.init(rawValue:)).flatMap(\.catalogTags))
}

struct SwipeDeck: View {
    @Environment(AppState.self) private var state
    @State private var offset: CGSize = .zero
    @State private var flinging = false
    @AppStorage("onlyOurServices") private var onlyOurs = false

    var body: some View {
        let tags = ourServiceTags(state)
        let filtered = onlyOurs && !tags.isEmpty ? state.deck.filter { !tags.isDisjoint(with: $0.streaming) } : state.deck
        let deck = Array(filtered.prefix(3))
        VStack(spacing: 16) {
            ZStack {
                if deck.isEmpty {
                    ContentUnavailableView {
                        Label("You've seen everything", systemImage: "popcorn")
                    } description: {
                        Text("Start over, or add a TMDB key in Settings for trending titles.")
                    } actions: {
                        Button("Start over") { state.mySwipes = [:] }.buttonStyle(.borderedProminent)
                    }
                }
                ForEach(Array(deck.enumerated()).reversed(), id: \.element.id) { index, movie in
                    let top = index == 0
                    MovieCard(movie: movie)
                        .overlay(alignment: .top) { if top { stamps } }
                        .scaleEffect(1 - CGFloat(index) * 0.04)
                        .offset(y: CGFloat(index) * 12)
                        .offset(top ? offset : .zero)
                        .rotationEffect(.degrees(top ? Double(offset.width / 18) : 0))
                        .gesture(drag(movie), including: top ? .all : .subviews)
                        .allowsHitTesting(top)
                        .accessibilityHidden(!top)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)

            if let top = deck.first {
                HStack(spacing: 48) {
                    circleButton("xmark", .red, "Skip \(top.title)") { fling(top, liked: false) }
                    circleButton("heart.fill", .green, "Like \(top.title)") { fling(top, liked: true) }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var stamps: some View {
        HStack {
            stamp("LIKE", .green).opacity(Double(max(0, offset.width) / 120))
            Spacer()
            stamp("NOPE", .red).opacity(Double(max(0, -offset.width) / 120))
        }
        .padding(24)
    }

    private func stamp(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .rotationEffect(.degrees(text == "LIKE" ? -14 : 14))
    }

    private func circleButton(_ symbol: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title.bold())
                .foregroundStyle(color)
                .frame(width: 68, height: 68)
                .surface(Circle())
                .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2))
        }
        .accessibilityLabel(label)
    }

    private func drag(_ movie: Movie) -> some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if abs(value.translation.width) > 120 || abs(value.predictedEndTranslation.width) > 320 {
                    fling(movie, liked: value.translation.width > 0)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                }
            }
    }

    private func fling(_ movie: Movie, liked: Bool) {
        guard !flinging else { return }
        flinging = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeIn(duration: 0.22)) { offset = CGSize(width: liked ? 600 : -600, height: 60) }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            state.swipe(movie, liked: liked)
            offset = .zero
            flinging = false
        }
    }
}

struct MovieCard: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterView(movie: movie)
                .frame(maxHeight: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(movie.title).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    Text(movie.isShow ? "SERIES" : "FILM")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(.secondary))
                }
                Text([movie.year > 0 ? String(movie.year) : "", movie.genres.joined(separator: " · "), movie.runtimeText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !movie.streaming.isEmpty {
                    HStack {
                        ForEach(movie.streaming, id: \.self) { tag in
                            let service = StreamingService.allCases.first { $0.catalogTags.contains(tag) }
                            if let url = service?.searchURL(for: movie.title) {
                                Link(destination: url) {
                                    Label(tag, systemImage: "play.fill")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(.tint.opacity(0.3)))
                                }
                                .accessibilityLabel("Watch on \(tag)")
                            } else {
                                Text(tag)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(.white.opacity(0.12)))
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .surface(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}

/// Stylized poster: generated art for the built-in catalog, the real poster for TMDB titles.
struct PosterView: View {
    let movie: Movie

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: movie.hue, saturation: 0.75, brightness: 0.55),
                                    Color(hue: (movie.hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url = movie.posterURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: movie.symbol)
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(movie.title.uppercased())
                        .font(.system(.title2, design: .serif).weight(.black))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal)
                    if movie.year > 0 {
                        Text(String(movie.year)).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .clipped()
    }
}

struct QueueList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.queue.isEmpty {
            ContentUnavailableView("No matches yet", systemImage: "popcorn",
                                   description: Text("When you both swipe right on the same title, it lands here."))
        } else {
            List {
                ForEach(state.queue, id: \.self) { id in
                    if let movie = state.movie(id) {
                        HStack(spacing: 12) {
                            PosterView(movie: movie)
                                .frame(width: 54, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(movie.title).font(.headline)
                                Text([movie.genres.first ?? "", movie.runtimeText, movie.streaming.first ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { state.queue.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
        }
    }
}
