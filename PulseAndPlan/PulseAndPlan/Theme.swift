import SwiftUI
import UIKit

// MARK: - Theme settings

enum ThemePreset: String, Codable, CaseIterable, Identifiable {
    case crimson, rose, ocean, sunset, forest, lavender, midnight
    var id: String { rawValue }
    var label: String { self == .crimson ? "Red Thread" : rawValue.capitalized }
    var accent: Color {
        switch self {
        case .crimson: Color(red: 0.95, green: 0.18, blue: 0.28)
        case .rose: Color(red: 1, green: 0.33, blue: 0.55)
        case .ocean: Color(red: 0.2, green: 0.75, blue: 1)
        case .sunset: Color(red: 1, green: 0.55, blue: 0.25)
        case .forest: Color(red: 0.3, green: 0.85, blue: 0.55)
        case .lavender: Color(red: 0.7, green: 0.55, blue: 1)
        case .midnight: Color(red: 0.55, green: 0.65, blue: 1)
        }
    }
    var palette: [Color] {
        switch self {
        case .crimson: [Color(red: 0.55, green: 0.02, blue: 0.1), Color(red: 0.3, green: 0.02, blue: 0.12), Color(red: 0.85, green: 0.12, blue: 0.2)]
        case .rose: [Color(red: 0.75, green: 0.1, blue: 0.4), Color(red: 0.45, green: 0.1, blue: 0.6), Color(red: 1, green: 0.45, blue: 0.5)]
        case .ocean: [Color(red: 0, green: 0.35, blue: 0.7), Color(red: 0, green: 0.6, blue: 0.7), Color(red: 0.25, green: 0.2, blue: 0.7)]
        case .sunset: [Color(red: 0.9, green: 0.35, blue: 0.2), Color(red: 0.75, green: 0.15, blue: 0.45), Color(red: 1, green: 0.7, blue: 0.3)]
        case .forest: [Color(red: 0.05, green: 0.45, blue: 0.3), Color(red: 0.1, green: 0.6, blue: 0.55), Color(red: 0.4, green: 0.6, blue: 0.15)]
        case .lavender: [Color(red: 0.45, green: 0.3, blue: 0.85), Color(red: 0.75, green: 0.4, blue: 0.85), Color(red: 0.3, green: 0.45, blue: 0.9)]
        case .midnight: [Color(red: 0.1, green: 0.12, blue: 0.4), Color(red: 0.2, green: 0.1, blue: 0.35), Color(red: 0.05, green: 0.3, blue: 0.45)]
        }
    }
}

enum BackgroundEffect: String, Codable, CaseIterable, Identifiable {
    case oled, aurora, hearts, stars, gradient, photo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oled: "True black (OLED)"
        case .aurora: "Aurora"
        case .hearts: "Floating hearts"
        case .stars: "Starfield"
        case .gradient: "Gradient"
        case .photo: "My photo"
        }
    }
}

struct RGBA: Codable, Equatable {
    var r, g, b, a: Double
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }
    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
}

struct ThemeSettings: Codable, Equatable {
    var preset: ThemePreset = .crimson
    var customAccent: RGBA?
    var effect: BackgroundEffect = .oled
    var photoDim = 0.45
    var photoBlur = 4.0
    var glass = false
    var accent: Color { customAccent?.color ?? preset.accent }

    /// Liquid Glass needs iOS 26; on OLED black, cards stay black so their pixels stay off.
    var surface: SurfaceStyle {
        if glass, #available(iOS 26, *) { return .glass }
        return effect == .oled ? .black : .material
    }

    static var photoURL: URL { URL.documentsDirectory.appending(path: "background.jpg") }
}

// MARK: - Surfaces (cards, bars, pills)

enum SurfaceStyle { case material, black, glass }

extension EnvironmentValues {
    @Entry var surfaceStyle: SurfaceStyle = .material
}

private struct Surface<S: Shape>: ViewModifier {
    @Environment(\.surfaceStyle) private var style
    let shape: S

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            if #available(iOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        case .black:
            content
                .background(.black, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        case .material:
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct SheetSurface: ViewModifier {
    @Environment(\.surfaceStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .glass: content // iOS 26 sheets are Liquid Glass by default
        case .black: content.presentationBackground(.black)
        case .material: content.sheetSurface()
        }
    }
}

extension View {
    /// The card/bar background for the chosen theme: material, OLED black, or Liquid Glass.
    func surface(_ shape: some Shape = Capsule()) -> some View { modifier(Surface(shape: shape)) }
    func sheetSurface() -> some View { modifier(SheetSurface()) }
}

// MARK: - Background

struct ThemedBackground: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = state.theme
        ZStack {
            Color.black
            switch theme.effect {
            case .oled:
                // Pure #000 keeps OLED pixels off (deepest black, least battery); one faint accent glow up top.
                RadialGradient(colors: [theme.accent.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 320)
            case .aurora:
                AuroraView(colors: theme.preset.palette + [theme.accent], paused: reduceMotion)
            case .hearts:
                LinearGradient(colors: theme.preset.palette.map { $0.opacity(0.35) }, startPoint: .top, endPoint: .bottom)
                FloatingSymbols(symbol: "heart.fill", color: theme.accent, count: 22, paused: reduceMotion)
            case .stars:
                LinearGradient(colors: [.black, theme.preset.palette[0].opacity(0.4)], startPoint: .top, endPoint: .bottom)
                Starfield(paused: reduceMotion)
            case .gradient:
                LinearGradient(colors: theme.preset.palette.map { $0.opacity(0.7) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .photo:
                if let image = state.backgroundImage {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: theme.photoBlur)
                    }
                    Color.black.opacity(theme.photoDim)
                } else {
                    AuroraView(colors: theme.preset.palette, paused: reduceMotion)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct AuroraView: View {
    let colors: [Color]
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    ForEach(colors.indices, id: \.self) { i in
                        let phase = Double(i) * 1.7
                        Circle()
                            .fill(colors[i])
                            .frame(width: geo.size.width * 1.1)
                            .offset(x: cos(t * 0.13 + phase) * geo.size.width * 0.35,
                                    y: sin(t * 0.09 + phase * 1.3) * geo.size.height * 0.35)
                            .opacity(0.5)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blur(radius: 70)
            }
        }
    }
}

struct FloatingSymbols: View {
    let symbol: String
    let color: Color
    let count: Int
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                var image = ctx.resolve(Image(systemName: symbol))
                image.shading = .color(color)
                for i in 0..<count {
                    let seed = Double(i)
                    let speed = 0.03 + (seed.truncatingRemainder(dividingBy: 5)) * 0.012
                    let progress = (t * speed + seed * 0.137).truncatingRemainder(dividingBy: 1)
                    let x = (seed * 73).truncatingRemainder(dividingBy: 100) / 100 * size.width + sin(t * 0.8 + seed) * 18
                    let y = size.height * (1.1 - progress * 1.2)
                    let scale = 0.6 + (seed * 37).truncatingRemainder(dividingBy: 10) / 10
                    ctx.opacity = 0.15 + 0.35 * sin(progress * .pi)
                    ctx.draw(image, in: CGRect(x: x, y: y, width: 18 * scale, height: 16 * scale))
                }
            }
        }
    }
}

struct Starfield: View {
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<120 {
                    let seed = Double(i)
                    let x = (seed * 97.13).truncatingRemainder(dividingBy: 1) * size.width
                    let x2 = (seed * 61.7).truncatingRemainder(dividingBy: size.width)
                    let y = (seed * 53.9).truncatingRemainder(dividingBy: size.height)
                    let twinkle = 0.3 + 0.7 * abs(sin(t * (0.5 + seed.truncatingRemainder(dividingBy: 3) * 0.4) + seed))
                    let r = 0.6 + (seed * 13).truncatingRemainder(dividingBy: 3) * 0.5
                    ctx.opacity = twinkle
                    ctx.fill(Path(ellipseIn: CGRect(x: (x + x2) / 2, y: y, width: r * 2, height: r * 2)), with: .color(.white))
                }
            }
        }
    }
}

// MARK: - Splash

extension Color {
    static let redThread = Color(red: 0.86, green: 0.08, blue: 0.2)
}

/// A slack thread with one loose loop in the middle, like a knot tied between two pinkies.
struct ThreadShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addCurve(to: CGPoint(x: r.midX - 8, y: r.midY + 4),
                   control1: CGPoint(x: r.minX + r.width * 0.2, y: r.maxY),
                   control2: CGPoint(x: r.midX - 30, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.midX + 8, y: r.midY + 4),
                   control1: CGPoint(x: r.midX - 18, y: r.minY - 6),
                   control2: CGPoint(x: r.midX + 18, y: r.minY - 6))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY),
                   control1: CGPoint(x: r.midX + 30, y: r.maxY),
                   control2: CGPoint(x: r.minX + r.width * 0.8, y: r.maxY))
        return p
    }
}

struct SplashView: View {
    @Environment(AppState.self) private var state
    @State private var beat = false
    @State private var rings = false
    @State private var threadDrawn = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ThemedBackground().opacity(0.6)
            VStack(spacing: 18) {
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(state.theme.accent, lineWidth: 2)
                            .frame(width: 120, height: 120)
                            .scaleEffect(rings ? 2.4 : 0.6)
                            .opacity(rings ? 0 : 0.8)
                            .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(i) * 0.45), value: rings)
                    }
                    Image(systemName: "heart.fill")
                        .font(.system(size: 92))
                        .foregroundStyle(LinearGradient(colors: [state.theme.accent, state.theme.preset.palette[1]],
                                                        startPoint: .top, endPoint: .bottom))
                        .scaleEffect(beat ? 1.12 : 0.92)
                        .shadow(color: state.theme.accent.opacity(0.6), radius: 24)
                }
                Text("Red Thread")
                    .font(.system(size: 36, weight: .heavy, design: .serif))
                // The legend: an invisible red thread ties two people together, however far apart.
                ZStack {
                    ThreadShape()
                        .trim(from: 0, to: threadDrawn ? 1 : 0)
                        .stroke(Color.redThread, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .shadow(color: Color.redThread.opacity(0.8), radius: 6)
                        .frame(width: 150, height: 40)
                    HStack {
                        AvatarView(isMe: true, size: 56)
                        Spacer()
                        AvatarView(isMe: false, size: 56)
                    }
                    .frame(width: 230)
                }
                Text("tied together, however far apart")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .opacity(threadDrawn ? 1 : 0)
            }
        }
        .onAppear {
            rings = true
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { beat = true }
            withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { threadDrawn = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Red Thread")
    }
}

// MARK: - Tab bar

enum AppTab: String, CaseIterable, Identifiable {
    case pulse, map, watch, play, plan
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pulse: "heart.circle.fill"
        case .map: "map.fill"
        case .watch: "popcorn.fill"
        case .play: "gamecontroller.fill"
        case .plan: "calendar"
        }
    }
}

extension EnvironmentValues {
    /// False for tabs that are kept alive but hidden, so timers and game loops can pause.
    @Entry var isActiveTab = true
}

struct TabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .symbolEffect(.bounce, value: selected)
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background {
                        if selected {
                            Capsule().fill(.tint.opacity(0.2)).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        .surface(Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}
