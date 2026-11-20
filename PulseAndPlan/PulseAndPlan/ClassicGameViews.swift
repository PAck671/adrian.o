import SwiftUI

private struct GameStatus: View {
    let text: String
    let highlight: Bool

    var body: some View {
        Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(highlight ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.ultraThinMaterial)))
            .contentTransition(.numericText())
            .animation(.spring, value: text)
    }
}

// MARK: - Sea Battle

struct SeaBattleView: View {
    @Environment(AppState.self) private var state
    let code: String
    let role: GameRole
    private let game: SeaBattle

    init(code: String, role: GameRole) {
        self.code = code
        self.role = role
        game = SeaBattle(code: code)
    }

    private var progress: GameState { state.gameState(code: code, game: .seaBattle) }

    var body: some View {
        let moves = progress.moves
        let winner = game.winner(moves)
        let myTurn = winner == nil && SeaBattle.nextShooter(moves) == role
        let partner = state.settings.partnerName
        ScrollView {
            VStack(spacing: 14) {
                GameStatus(text: winner.map { $0 == role ? "You sank the whole fleet! 🏆" : "\(partner) sank your fleet 🌊" }
                           ?? (myTurn ? "Your turn: fire at enemy waters" : "Waiting for \(partner) to fire…"),
                           highlight: myTurn || winner == role)
                section("Enemy waters", sunk: game.sunkShips(of: role.opponent, moves: moves).count)
                board(target: role.opponent, moves: moves, interactive: myTurn)
                section("Your fleet", sunk: game.sunkShips(of: role, moves: moves).count)
                board(target: role, moves: moves, interactive: false)
                Button("New game", role: .destructive) {
                    var p = progress
                    p.moves = []
                    state.updateGame(p)
                }
            }
            .padding()
        }
    }

    private func section(_ title: String, sunk: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(sunk)/\(SeaBattle.fleetLengths.count) sunk").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func board(target: GameRole, moves: [Int], interactive: Bool) -> some View {
        let shots = Set(SeaBattle.shots(by: target.opponent, in: moves))
        let fleet = game.fleet(target)
        let showShips = target == role
        let sunk = Set(game.sunkShips(of: target, moves: moves).flatMap { $0 })
        let n = SeaBattle.size
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: n), spacing: 3) {
            ForEach(0..<(n * n), id: \.self) { cell in
                let shot = shots.contains(cell)
                let hit = shot && fleet.contains(cell)
                Button { fire(cell) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showShips && fleet.contains(cell) ? Color.gray.opacity(0.75) : Color.cyan.opacity(0.16))
                        if hit {
                            Text(sunk.contains(cell) ? "💥" : "🔥").font(.caption).transition(.scale.combined(with: .opacity))
                        } else if shot {
                            Circle().fill(.white.opacity(0.6)).frame(width: 6, height: 6).transition(.scale)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .disabled(!interactive || shot)
                .accessibilityLabel("Row \(cell / n + 1), column \(cell % n + 1)\(hit ? ", hit" : shot ? ", miss" : "")")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: moves)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.blue.opacity(interactive ? 0.35 : 0.18)))
    }

    private func fire(_ cell: Int) {
        var p = progress
        guard game.winner(p.moves) == nil, SeaBattle.nextShooter(p.moves) == role,
              !SeaBattle.shots(by: role, in: p.moves).contains(cell) else { return }
        p.moves.append(cell)
        state.updateGame(p)
        if game.fleet(role.opponent).contains(cell) { state.haptics.success() } else { state.haptics.play(.tap) }
    }
}

// MARK: - Four in a Row

struct FourInRowView: View {
    @Environment(AppState.self) private var state
    let code: String
    let role: GameRole

    private var progress: GameState { state.gameState(code: code, game: .fourInRow) }

    var body: some View {
        let moves = progress.moves
        let grid = FourInRow.grid(moves)
        let winner = FourInRow.winner(moves)
        let draw = FourInRow.isDraw(moves)
        let myTurn = winner == nil && !draw && FourInRow.nextPlayer(moves) == role
        let partner = state.settings.partnerName
        VStack(spacing: 18) {
            GameStatus(text: winner.map { $0 == role ? "Four in a row! You win 🏆" : "\(partner) connected four" }
                       ?? (draw ? "Board full: it's a draw" : myTurn ? "Your move \(disc(role))" : "\(partner) is thinking… \(disc(role.opponent))"),
                       highlight: myTurn || winner == role)
            HStack(spacing: 6) {
                ForEach(0..<FourInRow.columns, id: \.self) { col in
                    VStack(spacing: 6) {
                        ForEach((0..<FourInRow.rows).reversed(), id: \.self) { row in
                            ZStack {
                                Circle().fill(.black.opacity(0.55))
                                if let owner = grid[col][row] {
                                    Circle()
                                        .fill(owner == .a ? Color.red.gradient : Color.yellow.gradient)
                                        .padding(2)
                                        .transition(.offset(y: -CGFloat(FourInRow.rows - row) * 48).combined(with: .opacity))
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { drop(col) }
                    .accessibilityElement()
                    .accessibilityLabel("Column \(col + 1)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { drop(col) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.blue.gradient.opacity(0.75)))
            .animation(.spring(response: 0.38, dampingFraction: 0.62), value: moves)
            .disabled(!myTurn)
            Button("New game", role: .destructive) {
                var p = progress
                p.moves = []
                state.updateGame(p)
            }
            Spacer()
        }
        .padding()
    }

    private func disc(_ role: GameRole) -> String { role == .a ? "🔴" : "🟡" }

    private func drop(_ col: Int) {
        var p = progress
        guard FourInRow.winner(p.moves) == nil, FourInRow.nextPlayer(p.moves) == role, FourInRow.canDrop(p.moves, in: col) else { return }
        p.moves.append(col)
        state.updateGame(p)
        if FourInRow.winner(p.moves) == role { state.haptics.success() } else { state.haptics.play(.tap) }
    }
}

// MARK: - Block Drop Duel

struct BlockDropView: View {
    @Environment(AppState.self) private var state
    @Environment(\.isActiveTab) private var isActiveTab
    @Environment(\.scenePhase) private var scenePhase
    let code: String
    let role: GameRole
    @State private var game: BlockDrop
    @State private var paused = false
    @State private var dragColumns = 0
    @State private var flash = false

    private static let colors: [Color] = [.cyan, .indigo, .orange, .yellow, .mint, .purple, .pink]

    init(code: String, role: GameRole) {
        self.code = code
        self.role = role
        _game = State(initialValue: BlockDrop(code: code))
    }

    private var progress: GameState { state.gameState(code: code, game: .blockDrop) }
    private var running: Bool { !game.over && !paused && isActiveTab && scenePhase == .active }

    var body: some View {
        let partnerScore = progress.scores[role.opponent.rawValue] ?? 0
        let partnerDone = progress.finished.contains(role.opponent.rawValue)
        VStack(spacing: 12) {
            HStack {
                scoreBox("You", game.score, done: game.over)
                Spacer()
                Text("VS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                scoreBox(state.settings.partnerName, partnerScore, done: partnerDone)
            }
            HStack(alignment: .top, spacing: 12) {
                GeometryReader { geo in
                    boardCanvas
                        .contentShape(Rectangle())
                        .gesture(boardGesture(cellWidth: geo.size.width / CGFloat(BlockDrop.width)))
                }
                .aspectRatio(CGFloat(BlockDrop.width) / CGFloat(BlockDrop.height), contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(flash ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.15)), lineWidth: flash ? 3 : 1))
                .accessibilityLabel("Board. Drag sideways to move, tap to rotate, swipe down to drop.")
                VStack(spacing: 12) {
                    Text("NEXT").font(.caption2.bold()).foregroundStyle(.secondary)
                    nextPreview
                    stat("LINES", game.lines)
                    stat("LEVEL", game.level)
                    Button { paused.toggle() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .disabled(game.over)
                    .accessibilityLabel(paused ? "Resume" : "Pause")
                }
                .frame(width: 70)
            }
            if game.over {
                resultCard(partnerScore: partnerScore, partnerDone: partnerDone)
            } else {
                controls
            }
        }
        .padding()
        .task(id: running) {
            while running, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(game.dropInterval))
                guard running, !Task.isCancelled else { return }
                if let cleared = game.step() { locked(cleared) }
            }
        }
    }

    private var boardCanvas: some View {
        Canvas { ctx, size in
            let cw = size.width / CGFloat(BlockDrop.width), ch = size.height / CGFloat(BlockDrop.height)
            func rect(_ x: Int, _ y: Int) -> Path {
                Path(roundedRect: CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw, height: ch).insetBy(dx: 1, dy: 1), cornerRadius: 3)
            }
            for y in 0..<BlockDrop.height {
                for x in 0..<BlockDrop.width {
                    let v = game.board[y][x]
                    ctx.fill(rect(x, y), with: .color(v == 0 ? .white.opacity(0.04) : Self.colors[v - 1]))
                }
            }
            guard !game.over else { return }
            var ghost = game.piece
            ghost.y = game.landingY
            for (x, y) in BlockDrop.cells(ghost) where y >= 0 {
                ctx.stroke(rect(x, y), with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            for (x, y) in BlockDrop.cells(game.piece) where y >= 0 {
                ctx.fill(rect(x, y), with: .color(Self.colors[game.piece.kind]))
            }
        }
    }

    private var nextPreview: some View {
        Canvas { ctx, size in
            let cells = BlockDrop.cells(BlockPiece(kind: game.nextKind, x: 0))
            let side = size.width / 4
            for (x, y) in cells {
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(x) * side, y: CGFloat(y) * side + side / 2, width: side, height: side).insetBy(dx: 1, dy: 1),
                              cornerRadius: 2), with: .color(Self.colors[game.nextKind]))
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            control("arrow.left", "Left") { game.move(-1) }
            control("arrow.clockwise", "Rotate") { game.rotate() }
            control("arrow.right", "Right") { game.move(1) }
            control("arrow.down", "Down") { if let cleared = game.step() { locked(cleared) } }
            control("arrow.down.to.line", "Drop") { locked(game.hardDrop()) }
        }
        .disabled(paused)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func boardGesture(cellWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard running else { return }
                let target = Int(value.translation.width / max(cellWidth, 1))
                while dragColumns < target { game.move(1); dragColumns += 1 }
                while dragColumns > target { game.move(-1); dragColumns -= 1 }
            }
            .onEnded { value in
                defer { dragColumns = 0 }
                guard running else { return }
                let t = value.translation
                if abs(t.width) < 8, abs(t.height) < 8 {
                    game.rotate()
                } else if t.height > 70, abs(t.width) < cellWidth * 1.5 {
                    locked(game.hardDrop())
                }
            }
    }

    private func scoreBox(_ name: String, _ score: Int, done: Bool) -> some View {
        VStack(spacing: 2) {
            Text(name).font(.caption.bold()).foregroundStyle(.secondary)
            Text("\(score)").font(.title2.monospacedDigit().bold()).contentTransition(.numericText(value: Double(score)))
            if done { Text("topped out").font(.caption2).foregroundStyle(.secondary) }
        }
        .animation(.spring, value: score)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
            Text("\(value)").font(.headline.monospacedDigit())
        }
    }

    private func resultCard(partnerScore: Int, partnerDone: Bool) -> some View {
        let partner = state.settings.partnerName
        let verdict = !partnerDone ? "\(partner) is still playing…"
            : game.score > partnerScore ? "You win the duel! 🏆" : game.score == partnerScore ? "Tie!" : "\(partner) wins this one"
        return VStack(spacing: 10) {
            Text("Game over · \(game.score) pts").font(.headline)
            Text(verdict).foregroundStyle(.secondary)
            Button("Play again") { restart() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .surface(RoundedRectangle(cornerRadius: 16))
    }

    private func locked(_ cleared: Int) {
        if cleared > 0 {
            state.haptics.play(cleared >= 4 ? .heartbeat : .doubleSqueeze)
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation { flash = false }
            }
        }
        var p = progress
        p.scores[role.rawValue] = game.score
        if game.over, !p.finished.contains(role.rawValue) {
            p.finished.append(role.rawValue)
            state.haptics.error()
        }
        state.updateGame(p)
    }

    private func restart() {
        game = BlockDrop(code: code)
        paused = false
        var p = progress
        p.scores[role.rawValue] = 0
        p.finished.removeAll { $0 == role.rawValue }
        state.updateGame(p)
    }
}
