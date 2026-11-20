import SwiftUI

/// Deterministic RNG: same code → same puzzle on every phone, OS version and launch.
/// Hand-rolled (FNV-1a seed + SplitMix64) because Swift's Hasher is randomly seeded per process.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(code: String, salt: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (code.uppercased() + "|" + salt).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var items = items
        for i in stride(from: items.count - 1, to: 0, by: -1) { items.swapAt(i, int(i + 1)) }
        return items
    }
}

enum RoomCode {
    static func make(length: Int, digits: Bool) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ" + (digits ? "23456789" : ""))
        return String((0..<length).map { _ in chars.randomElement() ?? "A" })
    }
}

// MARK: - Circuit Defusal

enum WireColor: String, CaseIterable {
    case red, blue, yellow, white, black, green
    var color: Color {
        switch self {
        case .red: .red
        case .blue: .blue
        case .yellow: .yellow
        case .white: .white
        case .black: Color(white: 0.15)
        case .green: .green
        }
    }
}

enum DialLight: String, CaseIterable {
    case red, green, blue, amber
    var color: Color {
        switch self {
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .amber: .orange
        }
    }
}

enum PadColor: String, CaseIterable {
    case red, blue, green, yellow
    var color: Color {
        switch self {
        case .red: .red
        case .blue: .blue
        case .green: .green
        case .yellow: .yellow
        }
    }
}

struct SequenceRow: Hashable {
    let letter: String
    let colors: [PadColor]
}

/// Module indices: 0 wires, 1 symbols, 2 dial, 3 sequence.
struct CircuitPuzzle {
    static let symbolPool = ["star.fill", "moon.fill", "bolt.fill", "leaf.fill", "flame.fill", "drop.fill",
                             "snowflake", "sparkle", "hexagon.fill", "triangle.fill", "seal.fill", "atom",
                             "hare.fill", "tortoise.fill", "crown.fill", "key.fill"]

    let serial: String
    let wires: [WireColor]
    let wireRuleColor: WireColor
    let wireIfNone: Int   // 1-based
    let wireIfMany: Int   // 1-based
    let symbolColumn: [String]
    let panelSymbols: [String]
    let light: DialLight
    let displayNumber: Int
    let dialOffsets: [DialLight: Int]
    let sequenceTable: [SequenceRow]
    let stageLetter: String

    init(code: String) {
        var r = SeededRandom(code: code, salt: "circuit")
        let letters = Array("ABCDEFGHJKLMNPRSTUVWXYZ").map(String.init)
        serial = r.pick(letters) + String(r.int(10)) + "-" + r.pick(letters) + String(r.int(10))
        wires = (0..<(3 + r.int(4))).map { _ in r.pick(WireColor.allCases) }
        wireRuleColor = r.pick(WireColor.allCases)
        wireIfNone = 1 + r.int(3)
        wireIfMany = 1 + r.int(3)
        symbolColumn = Array(r.shuffled(Self.symbolPool).prefix(7))
        panelSymbols = Array(r.shuffled(symbolColumn).prefix(4))
        light = r.pick(DialLight.allCases)
        displayNumber = r.int(10)
        dialOffsets = Dictionary(uniqueKeysWithValues: DialLight.allCases.map { ($0, 1 + r.int(9)) })
        let stageLetters = Array(r.shuffled(letters).prefix(5))
        sequenceTable = stageLetters.map { SequenceRow(letter: $0, colors: (0..<4).map { _ in r.pick(PadColor.allCases) }) }
        stageLetter = r.pick(stageLetters)
    }

    var serialEndsOdd: Bool { (serial.last?.wholeNumberValue ?? 0) % 2 == 1 }

    /// 0-based index of the wire to cut.
    var wireToCut: Int {
        let matches = wires.indices.filter { wires[$0] == wireRuleColor }
        switch matches.count {
        case 0: return wireIfNone - 1
        case 1: return matches[0]
        default: return wireIfMany - 1
        }
    }
    var symbolOrder: [String] { symbolColumn.filter(panelSymbols.contains) }
    var dialTarget: Int { (displayNumber + (dialOffsets[light] ?? 0) + (serialEndsOdd ? 5 : 0)) % 10 }
    var sequence: [PadColor] { sequenceTable.first { $0.letter == stageLetter }?.colors ?? [] }
}

// MARK: - Blind Labyrinth

enum Direction: CaseIterable {
    case up, right, down, left
    var dx: Int { self == .right ? 1 : self == .left ? -1 : 0 }
    var dy: Int { self == .down ? 1 : self == .up ? -1 : 0 }
    var opposite: Direction {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
    var symbol: String { "arrow.\(self)" }
}

struct Labyrinth {
    static let size = 7
    let open: [Set<Direction>]   // passable sides per cell
    let traps: Set<Int>
    let switchCell: Int
    let start = 0
    var exit: Int { Self.size * Self.size - 1 }

    init(code: String) {
        var r = SeededRandom(code: code, salt: "labyrinth")
        let count = Self.size * Self.size
        var open = Array(repeating: Set<Direction>(), count: count)
        var visited: Set<Int> = [0]
        var stack = [0]
        // Iterative recursive-backtracker → a perfect maze (exactly one route between any two cells).
        while let cell = stack.last {
            let options = Direction.allCases.compactMap { d -> (Direction, Int)? in
                guard let next = Self.neighbor(cell, d), !visited.contains(next) else { return nil }
                return (d, next)
            }
            guard !options.isEmpty else { stack.removeLast(); continue }
            let (d, next) = r.pick(options)
            open[cell].insert(d)
            open[next].insert(d.opposite)
            visited.insert(next)
            stack.append(next)
        }
        let deadEnds = (1..<(count - 1)).filter { open[$0].count == 1 }
        let switchCell = deadEnds.isEmpty ? Self.size * (Self.size / 2) : r.pick(deadEnds)
        // Traps only off the unique start→switch→exit route, so every maze stays solvable.
        let route = Set(Self.path(open, from: 0, to: switchCell) + Self.path(open, from: switchCell, to: count - 1))
        let candidates = (1..<(count - 1)).filter { !route.contains($0) }
        self.open = open
        self.switchCell = switchCell
        self.traps = Set(r.shuffled(candidates).prefix(6))
    }

    static func neighbor(_ cell: Int, _ d: Direction) -> Int? {
        let x = cell % size + d.dx, y = cell / size + d.dy
        guard (0..<size).contains(x), (0..<size).contains(y) else { return nil }
        return y * size + x
    }

    func move(from cell: Int, _ d: Direction) -> Int? {
        open[cell].contains(d) ? Self.neighbor(cell, d) : nil
    }

    /// BFS route (inclusive). Empty if unreachable.
    static func path(_ open: [Set<Direction>], from a: Int, to b: Int, avoiding blocked: Set<Int> = []) -> [Int] {
        var parent: [Int: Int] = [a: a]
        var queue = [a]
        var head = 0
        while head < queue.count {
            let cell = queue[head]; head += 1
            if cell == b { break }
            for d in open[cell] {
                guard let next = neighbor(cell, d), parent[next] == nil, !blocked.contains(next) else { continue }
                parent[next] = cell
                queue.append(next)
            }
        }
        guard parent[b] != nil else { return [] }
        var route = [b]
        while let last = route.last, last != a, let p = parent[last] { route.append(p) }
        return route.reversed()
    }
}
