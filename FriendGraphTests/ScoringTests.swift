import XCTest
@testable import FriendGraph

final class ScoringTests: XCTestCase {
    /// Local parts for a plain UTC clock, so tests do not depend on the machine's time zone.
    private func utc(_ t: Double) -> (day: Int, weekday: Int, hour: Int) {
        let day = Int((t / 86400).rounded(.down))
        return (day, ((day + 4) % 7 + 7) % 7 + 1, Int((t - Double(day) * 86400) / 3600))
    }

    /// A conversation: `count` exchanges spread over `days`, with replies after `reply` seconds.
    private func chat(count: Int, days: Double, reply: Double, calls: Int = 0, start: Double = 0) -> Scoring.Raw {
        var raw = Scoring.Raw()
        for i in 0..<count {
            let t = start + Double(i) * days * 86400 / Double(count) + 19 * 3600
            raw.events.append(.init(time: t, outgoing: i % 2 == 0))
            raw.events.append(.init(time: t + reply, outgoing: i % 2 != 0))
        }
        raw.calls = calls
        raw.callMinutes = Double(calls) * 6
        return raw
    }

    func testHandleKeysMergeNumberFormats() {
        XCTAssertEqual(Handle.key("+44 7700 900123"), Handle.key("07700900123"))
        XCTAssertEqual(Handle.key("+447700900123@s.whatsapp.net"), "700900123")
        XCTAssertEqual(Handle.key("Someone@Example.com"), "someone@example.com")
        XCTAssertEqual(Handle.key("12345"), "12345")          // too short to be a phone number
    }

    func testOneWayThreadsAreLeftOut() {
        var broadcast = Scoring.Raw()
        for i in 0..<50 { broadcast.events.append(.init(time: Double(i) * 86400, outgoing: false)) }
        let rows = Scoring.score(people: ["shop": broadcast, "friend": chat(count: 20, days: 100, reply: 120)],
                                 order: ["shop", "friend"], family: [], local: utc)
        XCTAssertEqual(rows.map(\.key), ["friend"])
    }

    func testSteadyFriendWithCallsOutranksABriefBurst() {
        let people = [
            "steady": chat(count: 300, days: 350, reply: 180, calls: 30),
            "burst": chat(count: 6, days: 2, reply: 20, start: 340 * 86400),
            "middling": chat(count: 60, days: 200, reply: 1800, calls: 2),
            "distant": chat(count: 12, days: 300, reply: 7200),
        ]
        let rows = Scoring.score(people: people, order: ["burst", "steady", "middling", "distant"], family: [], local: utc)
        XCTAssertEqual(rows.first?.key, "steady")
        XCTAssertLessThan(rows.firstIndex { $0.key == "burst" }!, rows.count)
        XCTAssertGreaterThan(rows.first!.score, rows.first { $0.key == "burst" }!.score)
        for row in rows { XCTAssertTrue((0...1).contains(row.score)) }
    }

    func testFamilySharingAddsABoost() {
        let people = ["a": chat(count: 40, days: 200, reply: 300), "b": chat(count: 40, days: 200, reply: 300)]
        let plain = Scoring.score(people: people, order: ["a", "b"], family: [], local: utc)
        let boosted = Scoring.score(people: people, order: ["a", "b"], family: ["b"], local: utc)
        let before = plain.first { $0.key == "b" }!.score, after = boosted.first { $0.key == "b" }!.score
        XCTAssertEqual(after, min(1, before + 0.10), accuracy: 1e-9)
        XCTAssertEqual(boosted.first?.key, "b")
    }

    func testReplyTimesAreMedians() {
        let rows = Scoring.score(people: ["a": chat(count: 10, days: 30, reply: 600)], order: ["a"], family: [], local: utc)
        XCTAssertEqual(rows[0].myReplyMinutes ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(rows[0].theirReplyMinutes ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(rows[0].count, 20)
    }

    func testNoEventsGivesNoRows() {
        XCTAssertTrue(Scoring.score(people: [:], order: [], family: [], local: utc).isEmpty)
    }

    func testWarmthRunsFromAmberToViolet() {
        XCTAssertEqual(Pal.warmth(100), Pal.amber)
        XCTAssertEqual(Pal.warmth(197.5), Pal.rose)
        XCTAssertLessThan(Pal.warmth(400).r, Pal.rose.r)
    }
}
