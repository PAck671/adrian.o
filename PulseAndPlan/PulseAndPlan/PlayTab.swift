import SwiftUI

struct PlayTab: View {
    @Environment(AppState.self) private var state
    @State private var code = RoomCode.make(length: 4, digits: false)
    @State private var game: GameKind = .circuit
    @State private var role: GameRole = .a
    @State private var playing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("CODE", text: $code)
                            .font(.system(.largeTitle, design: .monospaced).bold())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: code) { _, new in
                                let clean = String(new.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(4))
                                if clean != new { code = clean }
                            }
                        Button("New") { code = RoomCode.make(length: 4, digits: false) }.buttonStyle(.bordered)
                    }
                } header: { Text("Game code") } footer: {
                    Text("Share these 4 letters. Both phones build the same puzzle from the code, so it works even offline.")
                }

                Section("Game") {
                    Picker("Game", selection: $game) {
                        ForEach(GameKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(game == .circuit
                         ? "Defuse a 4-module panel before the timer runs out. 3 strikes and it's over."
                         : "Escape a pitch-black maze. Hit the switch to unlock the exit and dodge the traps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Your role") {
                    Picker("Role", selection: $role) {
                        Text("Role A").tag(GameRole.a)
                        Text("Role B").tag(GameRole.b)
                    }
                    .pickerStyle(.segmented)
                    Text(roleDescription).font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button { playing = true } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity).font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(code.count != 4)
                } footer: {
                    if state.settings.mode == .demo {
                        Text("Demo tip: flip between A and B with the switch at the top of the game screen to try both roles on one phone.")
                    }
                }
            }
            .navigationTitle("Play")
            .navigationDestination(isPresented: $playing) { GameScreen(code: code, game: game, role: role) }
        }
    }

    private var roleDescription: String {
        switch (game, role) {
        case (.circuit, .a): "You see the control panel. Describe it and do what your partner says."
        case (.circuit, .b): "You see the rulebook. Ask questions and tell your partner what to press."
        case (.labyrinth, .a): "You only see where you've been. Move when your partner tells you."
        case (.labyrinth, .b): "You see the whole map, traps and switch. Guide your partner out."
        }
    }
}

struct GameScreen: View {
    let code: String
    let game: GameKind
    @State private var role: GameRole

    init(code: String, game: GameKind, role: GameRole) {
        self.code = code
        self.game = game
        _role = State(initialValue: role)
    }

    var body: some View {
        Group {
            switch (game, role) {
            case (.circuit, .a): CircuitPanel(puzzle: CircuitPuzzle(code: code), code: code)
            case (.circuit, .b): CircuitManual(puzzle: CircuitPuzzle(code: code), code: code)
            case (.labyrinth, .a): LabyrinthPlayer(maze: Labyrinth(code: code), code: code)
            case (.labyrinth, .b): LabyrinthGuide(maze: Labyrinth(code: code), code: code)
            }
        }
        .background(Color.black)
        .navigationTitle("\(game.label) · \(code)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Role", selection: $role) {
                    Text("A").tag(GameRole.a)
                    Text("B").tag(GameRole.b)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
        }
    }
}

// MARK: - Circuit Defusal · Role A (panel)

struct CircuitPanel: View {
    @Environment(AppState.self) private var state
    let puzzle: CircuitPuzzle
    let code: String
    @State private var cut: Set<Int> = []
    @State private var pressed: [String] = []
    @State private var dial = 0
    @State private var entered: [PadColor] = []
    @State private var started = Date()

    private static let timeLimit = 300.0
    private var progress: GameState { state.gameState(code: code, game: .circuit) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Self.timeLimit - context.date.timeIntervalSince(started))
            let over = progress.strikes >= 3 || remaining == 0
            let defused = progress.solved.count == 4
            ScrollView {
                VStack(spacing: 16) {
                    statusBar(remaining: remaining)
                    if defused {
                        resultCard("Defused! 🎉", "You two make a great team.", .green)
                    } else if over {
                        resultCard("💥 Boom", progress.strikes >= 3 ? "Three strikes." : "Out of time.", .red)
                    }
                    wiresModule
                    symbolsModule
                    dialModule
                    sequenceModule
                    Button("Reset room", role: .destructive, action: reset).padding(.top)
                }
                .padding()
                .disabled(over || defused)
            }
        }
    }

    private func statusBar(remaining: Double) -> some View {
        HStack {
            Text("SERIAL \(puzzle.serial)").font(.caption.monospaced().bold())
            Spacer()
            Text(String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60))
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(remaining < 60 ? .red : .primary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < progress.strikes ? "xmark.circle.fill" : "circle")
                        .foregroundStyle(i < progress.strikes ? .red : .secondary)
                }
            }
            .accessibilityLabel("\(progress.strikes) of 3 strikes")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.1)))
    }

    private func resultCard(_ title: String, _ subtitle: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.25)))
    }

    private func module<Content: View>(_ index: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        let solved = progress.solved.contains(index)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Circle().fill(solved ? .green : .red.opacity(0.6)).frame(width: 12, height: 12)
                    .accessibilityLabel(solved ? "Solved" : "Armed")
            }
            content()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(solved ? .green.opacity(0.6) : .clear, lineWidth: 2))
        .disabled(solved)
    }

    private var wiresModule: some View {
        module(0, "1 · Wires") {
            ForEach(puzzle.wires.indices, id: \.self) { i in
                Button {
                    cut.insert(i)
                    i == puzzle.wireToCut ? solve(0) : strike()
                } label: {
                    HStack {
                        Text("\(i + 1)").font(.caption.monospaced()).frame(width: 18)
                        Capsule()
                            .fill(puzzle.wires[i].color)
                            .frame(height: 10)
                            .overlay(Capsule().stroke(.white.opacity(0.3)))
                            .mask(cut.contains(i) ? AnyView(HStack(spacing: 18) { Rectangle(); Rectangle() }) : AnyView(Rectangle()))
                        Image(systemName: "scissors").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(cut.contains(i))
                .accessibilityLabel("Wire \(i + 1), \(puzzle.wires[i].rawValue)\(cut.contains(i) ? ", cut" : "")")
            }
        }
    }

    private var symbolsModule: some View {
        module(1, "2 · Symbols") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(puzzle.panelSymbols, id: \.self) { symbol in
                    Button {
                        let expected = puzzle.symbolOrder[pressed.count]
                        if symbol == expected {
                            pressed.append(symbol)
                            state.haptics.play(.tap)
                            if pressed.count == puzzle.symbolOrder.count { solve(1) }
                        } else {
                            pressed = []
                            strike()
                        }
                    } label: {
                        Image(systemName: symbol)
                            .font(.title)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(pressed.contains(symbol) ? Color.green.opacity(0.35) : Color(white: 0.16)))
                    }
                    .buttonStyle(.plain)
                    .disabled(pressed.contains(symbol))
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                }
            }
        }
    }

    private var dialModule: some View {
        module(2, "3 · Dial") {
            HStack(spacing: 16) {
                VStack {
                    Circle().fill(puzzle.light.color).frame(width: 26, height: 26).shadow(color: puzzle.light.color, radius: 8)
                    Text("LIGHT").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Light is \(puzzle.light.rawValue)")
                VStack {
                    Text("\(puzzle.displayNumber)").font(.system(size: 34, weight: .bold, design: .monospaced))
                    Text("DISPLAY").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(value: $dial, in: 0...9) {
                    Text("\(dial)").font(.system(size: 34, weight: .bold, design: .monospaced))
                }
                .fixedSize()
                .accessibilityLabel("Dial")
                .accessibilityValue("\(dial)")
            }
            Button("Lock in") { dial == puzzle.dialTarget ? solve(2) : strike() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
    }

    private var sequenceModule: some View {
        module(3, "4 · Sequence") {
            HStack {
                Text("STAGE").font(.caption2).foregroundStyle(.secondary)
                Text(puzzle.stageLetter).font(.system(size: 34, weight: .black, design: .monospaced))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < entered.count ? entered[i].color : Color(white: 0.2)).frame(width: 12, height: 12)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(PadColor.allCases, id: \.self) { color in
                    Button {
                        entered.append(color)
                        state.haptics.play(.tap)
                        guard entered.count == 4 else { return }
                        if entered == puzzle.sequence { solve(3) } else { strike() }
                        entered = []
                    } label: {
                        RoundedRectangle(cornerRadius: 12).fill(color.color).frame(height: 54)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.rawValue)
                }
            }
        }
    }

    private func solve(_ index: Int) {
        var p = progress
        p.solved.insert(index)
        state.updateGame(p)
        state.haptics.success()
    }

    private func strike() {
        var p = progress
        p.strikes += 1
        state.updateGame(p)
        state.haptics.error()
    }

    private func reset() {
        cut = []
        pressed = []
        dial = 0
        entered = []
        started = Date()
        state.updateGame(GameState(code: code.uppercased(), game: .circuit, updatedBy: state.settings.deviceId))
    }
}

// MARK: - Circuit Defusal · Role B (rulebook)

struct CircuitManual: View {
    @Environment(AppState.self) private var state
    let puzzle: CircuitPuzzle
    let code: String

    var body: some View {
        let progress = state.gameState(code: code, game: .circuit)
        List {
            Section {
                LabeledContent("Modules defused", value: "\(progress.solved.count) / 4")
                LabeledContent("Strikes", value: "\(progress.strikes) / 3")
            } header: { Text("Live status") }

            Section {
                Text("Wires are numbered from the top. Count the **\(puzzle.wireRuleColor.rawValue)** wires:")
                Text("• None → cut wire **#\(puzzle.wireIfNone)**")
                Text("• Exactly one → cut **that** wire")
                Text("• Two or more → cut wire **#\(puzzle.wireIfMany)**")
            } header: { manualHeader("1 · Wires", solved: progress.solved.contains(0)) }

            Section {
                Text("Your partner has 4 of the symbols below. They must press them in the order they appear here, top to bottom.")
                ForEach(Array(puzzle.symbolColumn.enumerated()), id: \.offset) { index, symbol in
                    HStack {
                        Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Image(systemName: symbol).font(.title2).frame(width: 40)
                        Text(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: { manualHeader("2 · Symbols", solved: progress.solved.contains(1)) }

            Section {
                Text("Dial = DISPLAY number + the light's value. If the serial number ends in an **odd** digit, add 5 more. Keep only the last digit.")
                ForEach(DialLight.allCases, id: \.self) { light in
                    HStack {
                        Circle().fill(light.color).frame(width: 14, height: 14)
                        Text(light.rawValue.capitalized)
                        Spacer()
                        Text("+\(puzzle.dialOffsets[light] ?? 0)").font(.body.monospaced().bold())
                    }
                }
            } header: { manualHeader("3 · Dial", solved: progress.solved.contains(2)) }

            Section {
                Text("Ask for the STAGE letter, then read out the four colors in order.")
                ForEach(puzzle.sequenceTable, id: \.self) { row in
                    HStack {
                        Text(row.letter).font(.title3.monospaced().bold()).frame(width: 30)
                        ForEach(Array(row.colors.enumerated()), id: \.offset) { _, color in
                            Text(color.rawValue)
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(color.color.opacity(0.35)))
                        }
                    }
                }
            } header: { manualHeader("4 · Sequence", solved: progress.solved.contains(3)) }
        }
    }

    private func manualHeader(_ title: String, solved: Bool) -> some View {
        HStack {
            Text(title)
            if solved { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        }
    }
}
