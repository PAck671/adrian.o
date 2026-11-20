import SwiftUI

// MARK: - Role A: fog of war

struct LabyrinthPlayer: View {
    @Environment(AppState.self) private var state
    let maze: Labyrinth
    let code: String
    @State private var visited: Set<Int> = [0]
    @State private var message = "It's dark. Ask your partner which way to go."

    private var progress: GameState { state.gameState(code: code, game: .labyrinth) }
    private var escaped: Bool { progress.solved.contains(0) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(progress.switchOn ? "Exit unlocked" : "Exit locked",
                      systemImage: progress.switchOn ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(progress.switchOn ? .green : .orange)
                Spacer()
                Label("\(progress.strikes) trap\(progress.strikes == 1 ? "" : "s")", systemImage: "burst.fill")
                    .foregroundStyle(.red)
            }
            .font(.subheadline.weight(.semibold))

            MazeGrid(maze: maze, revealed: { visited.contains($0) }, marker: marker)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.02)))

            Text(escaped ? "You escaped together! 🎉" : message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)

            dPad.disabled(escaped)
            Button("Reset room", role: .destructive, action: reset)
        }
        .padding()
    }

    private func marker(_ cell: Int) -> String? {
        if cell == progress.position { return state.settings.myAvatar }
        if cell == maze.exit { return "🚪" }
        if cell == maze.switchCell { return progress.switchOn ? "🟢" : "🔌" }
        return nil
    }

    private var dPad: some View {
        VStack(spacing: 8) {
            arrow(.up)
            HStack(spacing: 56) {
                arrow(.left)
                arrow(.right)
            }
            arrow(.down)
        }
    }

    private func arrow(_ direction: Direction) -> some View {
        Button { move(direction) } label: {
            Image(systemName: direction.symbol)
                .font(.title.bold())
                .frame(width: 64, height: 64)
                .surface(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Move \(String(describing: direction))")
    }

    private func move(_ direction: Direction) {
        var p = progress
        guard let next = maze.move(from: p.position, direction) else {
            state.haptics.bump()
            message = "Bump! A wall."
            return
        }
        p.position = next
        visited.insert(next)
        if maze.traps.contains(next) {
            p.strikes += 1
            p.position = maze.start
            message = "💥 A trap! Back to the start."
            state.haptics.error()
        } else if next == maze.switchCell, !p.switchOn {
            p.switchOn = true
            message = "Click. Something unlocked in the distance…"
            state.haptics.success()
        } else if next == maze.exit {
            if p.switchOn {
                p.solved.insert(0)
                state.haptics.success()
            } else {
                message = "The exit door is locked. Find the switch first."
                state.haptics.bump()
            }
        } else {
            message = "Step…"
            state.haptics.play(.tap)
        }
        state.updateGame(p)
    }

    private func reset() {
        visited = [0]
        message = "It's dark. Ask your partner which way to go."
        state.updateGame(GameState(code: code.uppercased(), game: .labyrinth, updatedBy: state.settings.deviceId))
    }
}

// MARK: - Role B: full map

struct LabyrinthGuide: View {
    @Environment(AppState.self) private var state
    let maze: Labyrinth
    let code: String

    var body: some View {
        let progress = state.gameState(code: code, game: .labyrinth)
        VStack(spacing: 16) {
            Text(progress.solved.contains(0) ? "They escaped! 🎉" : "Guide \(state.settings.partnerName) to the 🔌 switch, then the 🚪 exit.")
                .font(.headline)
                .multilineTextAlignment(.center)
            MazeGrid(maze: maze, revealed: { _ in true }) { cell in
                if cell == progress.position { return state.settings.partnerAvatar }
                if maze.traps.contains(cell) { return "💥" }
                if cell == maze.switchCell { return progress.switchOn ? "🟢" : "🔌" }
                if cell == maze.exit { return "🚪" }
                if cell == maze.start { return "🏁" }
                return nil
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.02)))
            HStack(spacing: 16) {
                Text("🏁 start")
                Text("💥 trap")
                Text("🔌 switch")
                Text("🚪 exit")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Label(progress.switchOn ? "Switch on" : "Switch off", systemImage: "power")
                Spacer()
                Label("Trap hits: \(progress.strikes)", systemImage: "burst.fill")
            }
            .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding()
    }
}

// MARK: - Grid

struct MazeGrid: View {
    let maze: Labyrinth
    let revealed: (Int) -> Bool
    let marker: (Int) -> String?

    var body: some View {
        let n = Labyrinth.size
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) / CGFloat(n)
            ZStack(alignment: .topLeading) {
                ForEach(0..<(n * n), id: \.self) { cell in
                    let shown = revealed(cell)
                    ZStack {
                        Rectangle().fill(shown ? Color(white: 0.15) : Color(white: 0.04))
                        if shown {
                            CellWalls(open: maze.open[cell]).stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            if let mark = marker(cell) { Text(mark).font(.system(size: side * 0.5)) }
                        }
                    }
                    .frame(width: side, height: side)
                    .offset(x: CGFloat(cell % n) * side, y: CGFloat(cell / n) * side)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Maze map")
    }
}

struct CellWalls: Shape {
    let open: Set<Direction>

    func path(in r: CGRect) -> Path {
        var p = Path()
        let corners: [Direction: (CGPoint, CGPoint)] = [
            .up: (CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
            .right: (CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
            .down: (CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
            .left: (CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)),
        ]
        for (side, line) in corners where !open.contains(side) {
            p.move(to: line.0)
            p.addLine(to: line.1)
        }
        return p
    }
}
