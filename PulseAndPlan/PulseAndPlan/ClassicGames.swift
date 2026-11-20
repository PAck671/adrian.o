import Foundation

extension GameRole {
    var opponent: GameRole { self == .a ? .b : .a }
}

// MARK: - Sea Battle

/// Turn-based fleet hunt on an 8×8 grid. Moves alternate A, B, A… and each move is the cell fired at.
struct SeaBattle {
    static let size = 8
    static let fleetLengths = [4, 3, 3, 2, 2]

    // shortcut: both fleets derive from the shared code so the game works offline; a player who reads the
    // code could compute the other fleet. Upgrade to private placement + hit/miss replies over sync if that matters.
    let ships: [GameRole: [[Int]]]

    init(code: String) {
        var result: [GameRole: [[Int]]] = [:]
        for role in GameRole.allCases {
            var r = SeededRandom(code: code, salt: "sea-\(role.rawValue)")
            var taken = Set<Int>()
            var placed: [[Int]] = []
            for length in Self.fleetLengths {
                for _ in 0..<500 {
                    let horizontal = r.int(2) == 0
                    let x = r.int(horizontal ? Self.size - length + 1 : Self.size)
                    let y = r.int(horizontal ? Self.size : Self.size - length + 1)
                    let cells = (0..<length).map { horizontal ? y * Self.size + x + $0 : (y + $0) * Self.size + x }
                    if taken.isDisjoint(with: cells) {
                        taken.formUnion(cells)
                        placed.append(cells)
                        break
                    }
                }
            }
            result[role] = placed
        }
        ships = result
    }

    func fleet(_ role: GameRole) -> Set<Int> { Set(ships[role, default: []].flatMap { $0 }) }

    static func shooter(ofMove index: Int) -> GameRole { index % 2 == 0 ? .a : .b }
    static func nextShooter(_ moves: [Int]) -> GameRole { shooter(ofMove: moves.count) }
    static func shots(by role: GameRole, in moves: [Int]) -> [Int] {
        moves.enumerated().filter { shooter(ofMove: $0.offset) == role }.map(\.element)
    }

    func winner(_ moves: [Int]) -> GameRole? {
        GameRole.allCases.first { fleet($0.opponent).isSubset(of: Self.shots(by: $0, in: moves)) }
    }

    func sunkShips(of role: GameRole, moves: [Int]) -> [[Int]] {
        let incoming = Set(Self.shots(by: role.opponent, in: moves))
        return ships[role, default: []].filter { Set($0).isSubset(of: incoming) }
    }

    static func neighbors(_ cell: Int) -> [Int] {
        let x = cell % size, y = cell / size
        return [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            .filter { (0..<size).contains($0.0) && (0..<size).contains($0.1) }
            .map { $0.1 * size + $0.0 }
    }
}

// MARK: - Four in a Row

/// 7×6 board. Moves are column indices; A (first) plays red.
enum FourInRow {
    static let columns = 7
    static let rows = 6

    /// grid[column][row], row 0 at the bottom.
    static func grid(_ moves: [Int]) -> [[GameRole?]] {
        var g = Array(repeating: [GameRole?](), count: columns)
        for (i, col) in moves.enumerated() where (0..<columns).contains(col) && g[col].count < rows {
            g[col].append(i % 2 == 0 ? .a : .b)
        }
        return g.map { $0 + Array(repeating: nil, count: rows - $0.count) }
    }

    static func canDrop(_ moves: [Int], in column: Int) -> Bool {
        (0..<columns).contains(column) && moves.filter { $0 == column }.count < rows
    }

    static func nextPlayer(_ moves: [Int]) -> GameRole { moves.count % 2 == 0 ? .a : .b }

    static func wins(_ g: [[GameRole?]], _ player: GameRole) -> Bool {
        for c in 0..<columns {
            for r in 0..<rows where g[c][r] == player {
                for (dc, dr) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                    let line = (1..<4).allSatisfy { k in
                        let cc = c + dc * k, rr = r + dr * k
                        return (0..<columns).contains(cc) && (0..<rows).contains(rr) && g[cc][rr] == player
                    }
                    if line { return true }
                }
            }
        }
        return false
    }

    static func winner(_ moves: [Int]) -> GameRole? {
        let g = grid(moves)
        return GameRole.allCases.first { wins(g, $0) }
    }

    static func isDraw(_ moves: [Int]) -> Bool { winner(moves) == nil && moves.count >= columns * rows }
}

// MARK: - Block Drop

struct BlockPiece: Equatable {
    var kind: Int
    var rotation = 0
    var x = 3
    var y = 0
}

/// Falling-block puzzle. Both phones draw pieces from the same seeded 7-bag, so the duel is fair.
struct BlockDrop {
    static let width = 10
    static let height = 20
    /// Spawn-rotation cells (x right, y down) inside each piece's rotation box.
    static let shapes: [[(Int, Int)]] = [
        [(0, 1), (1, 1), (2, 1), (3, 1)], // I
        [(0, 0), (0, 1), (1, 1), (2, 1)], // J
        [(2, 0), (0, 1), (1, 1), (2, 1)], // L
        [(0, 0), (1, 0), (0, 1), (1, 1)], // O
        [(1, 0), (2, 0), (0, 1), (1, 1)], // S
        [(1, 0), (0, 1), (1, 1), (2, 1)], // T
        [(0, 0), (1, 0), (1, 1), (2, 1)], // Z
    ]

    var board = Array(repeating: Array(repeating: 0, count: width), count: height) // [row][col]; 0 empty, else kind + 1
    var piece = BlockPiece(kind: 0)
    var nextKind = 0
    var score = 0
    var lines = 0
    var over = false
    private var rng: SeededRandom
    private var bag: [Int] = []

    init(code: String) {
        rng = SeededRandom(code: code, salt: "blocks")
        nextKind = drawKind()
        spawn()
    }

    var level: Int { lines / 10 + 1 }
    var dropInterval: Double { max(0.08, 0.8 - Double(level - 1) * 0.07) }

    static func boxSize(_ kind: Int) -> Int { kind == 0 ? 4 : kind == 3 ? 2 : 3 }

    static func cells(_ p: BlockPiece) -> [(Int, Int)] {
        let n = boxSize(p.kind)
        return shapes[p.kind].map { cell in
            var (x, y) = cell
            for _ in 0..<(p.rotation % 4) { (x, y) = (n - 1 - y, x) }
            return (p.x + x, p.y + y)
        }
    }

    func fits(_ p: BlockPiece) -> Bool {
        Self.cells(p).allSatisfy { x, y in
            (0..<Self.width).contains(x) && y < Self.height && (y < 0 || board[y][x] == 0)
        }
    }

    /// Row the current piece would land on (for the ghost preview).
    var landingY: Int {
        var p = piece
        while true {
            var next = p
            next.y += 1
            if !fits(next) { return p.y }
            p = next
        }
    }

    private mutating func drawKind() -> Int {
        if bag.isEmpty { bag = rng.shuffled(Array(0..<7)) }
        return bag.removeFirst()
    }

    private mutating func spawn() {
        piece = BlockPiece(kind: nextKind, x: nextKind == 3 ? 4 : 3)
        nextKind = drawKind()
        if !fits(piece) { over = true }
    }

    @discardableResult
    mutating func move(_ dx: Int) -> Bool {
        var p = piece
        p.x += dx
        guard !over, fits(p) else { return false }
        piece = p
        return true
    }

    mutating func rotate() {
        guard !over else { return }
        for kick in [0, -1, 1, -2, 2] {
            var p = piece
            p.rotation += 1
            p.x += kick
            if fits(p) {
                piece = p
                return
            }
        }
    }

    /// Gravity tick. Returns cleared line count when the piece locks, nil while it is still falling.
    @discardableResult
    mutating func step() -> Int? {
        guard !over else { return nil }
        var p = piece
        p.y += 1
        if fits(p) {
            piece = p
            return nil
        }
        return lock()
    }

    @discardableResult
    mutating func hardDrop() -> Int {
        guard !over else { return 0 }
        let distance = landingY - piece.y
        piece.y = landingY
        score += distance * 2
        return lock()
    }

    private mutating func lock() -> Int {
        let cells = Self.cells(piece)
        if cells.contains(where: { $0.1 < 0 }) {
            over = true
            return 0
        }
        for (x, y) in cells { board[y][x] = piece.kind + 1 }
        let cleared = board.filter { !$0.contains(0) }.count
        board.removeAll { !$0.contains(0) }
        board.insert(contentsOf: Array(repeating: Array(repeating: 0, count: Self.width), count: cleared), at: 0)
        score += [0, 100, 300, 500, 800][cleared] * level
        lines += cleared
        spawn()
        return cleared
    }
}
