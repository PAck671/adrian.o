import CoreLocation
import XCTest
@testable import PulseAndPlan

final class PulseAndPlanTests: XCTestCase {
    private let codes = ["ABCD", "LOVE", "ZZZZ", "QWER", "MOON", "PING", "HUGS", "KISS"]

    func testSeededRandomDependsOnlyOnCode() {
        var a = SeededRandom(code: "LOVE", salt: "x")
        var b = SeededRandom(code: "love", salt: "x")
        XCTAssertEqual((0..<8).map { _ in a.next() }, (0..<8).map { _ in b.next() })
        var c = SeededRandom(code: "LOVE", salt: "x")
        var d = SeededRandom(code: "KISS", salt: "x")
        XCTAssertNotEqual(c.next(), d.next())
    }

    func testCircuitPuzzleIsDeterministicAndAnswerable() {
        for code in codes {
            let p = CircuitPuzzle(code: code), q = CircuitPuzzle(code: code)
            XCTAssertEqual(p.serial, q.serial)
            XCTAssertEqual(p.wires, q.wires)
            XCTAssertEqual(p.symbolColumn, q.symbolColumn)
            XCTAssertEqual(p.sequenceTable, q.sequenceTable)
            XCTAssertTrue(p.wires.indices.contains(p.wireToCut), code)
            XCTAssertEqual(p.symbolOrder.count, 4, code)
            XCTAssertTrue((0..<10).contains(p.dialTarget), code)
            XCTAssertEqual(p.sequence.count, 4, code)
        }
    }

    func testEveryLabyrinthIsSolvableAroundTraps() {
        for code in codes {
            let m = Labyrinth(code: code)
            XCTAssertEqual(Labyrinth(code: code).traps, m.traps, code)
            XCTAssertFalse(m.traps.isEmpty, code)
            XCTAssertFalse(m.traps.contains(m.switchCell) || m.traps.contains(m.exit) || m.traps.contains(m.start), code)
            XCTAssertFalse(Labyrinth.path(m.open, from: m.start, to: m.switchCell, avoiding: m.traps).isEmpty, code)
            XCTAssertFalse(Labyrinth.path(m.open, from: m.switchCell, to: m.exit, avoiding: m.traps).isEmpty, code)
        }
    }

    func testBothFreeWindowsChicagoTokyo() throws {
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let noonChicago = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T18:00:00Z"))
        let hours = Overlap.hours(of: noonChicago, in: chicago)
        let hourOf = { (d: Date) in Overlap.calendar(chicago).component(.hour, from: d) }

        let free = hours.filter { Overlap.bothFree($0, myTZ: chicago, partnerTZ: tokyo, events: []) }
        XCTAssertEqual(free.map(hourOf), [17, 18, 19, 20, 21, 22]) // 08:00–13:00 next day in Tokyo

        let busy = SharedEvent(title: "Shift", kind: .busy, start: free[1], end: free[1].addingTimeInterval(3600), createdBy: UUID())
        let dateNight = SharedEvent(title: "Call", kind: .dateNight, start: free[3], end: free[3].addingTimeInterval(3600), createdBy: UUID())
        let freeAfter = hours.filter { Overlap.bothFree($0, myTZ: chicago, partnerTZ: tokyo, events: [busy, dateNight]) }
        XCTAssertEqual(freeAfter.map(hourOf), [17, 19, 20, 21, 22])
    }

    func testParsesSupabaseTimestampShapes() throws {
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T02:46:00Z"))
        for raw in ["2026-11-19T02:46:00+00:00", "2026-11-19 02:46:00+00", "2026-11-19T02:46:00.000000+00:00",
                    "2026-11-19T02:46:00Z", "2026-11-19T02:46:00", "2026-11-19T11:46:00+09:00"] {
            XCTAssertEqual(SupabaseSyncService.parseDate(raw), expected, raw)
        }
        let micro = try XCTUnwrap(SupabaseSyncService.parseDate("2026-11-19T02:46:00.123456+00:00"))
        XCTAssertEqual(micro.timeIntervalSince(expected), 0.123, accuracy: 0.0005)
    }

    func testFuzzySnapsToThreeKilometerGrid() {
        let real = CLLocationCoordinate2D(latitude: 35.6595, longitude: 139.7005)
        let fuzzy = real.fuzzed()
        XCTAssertEqual(fuzzy.latitude, 35.67, accuracy: 1e-9)
        XCTAssertEqual(fuzzy.longitude, 139.71, accuracy: 1e-9)
        XCTAssertLessThan(fuzzy.distance(to: real), 3000)
        // Nearby points collapse to the same published spot.
        let nearby = CLLocationCoordinate2D(latitude: 35.6610, longitude: 139.7020).fuzzed()
        XCTAssertEqual(nearby.latitude, fuzzy.latitude, accuracy: 1e-9)
        XCTAssertEqual(nearby.longitude, fuzzy.longitude, accuracy: 1e-9)
    }
}
