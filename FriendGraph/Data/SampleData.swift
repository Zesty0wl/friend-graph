import Foundation

/// A small deterministic random source, so sample data and layouts are the same on every launch.
struct Seeded {
    private var state: Int
    init(_ seed: Int) { state = seed }
    mutating func next() -> Double {
        state = (state * 16807) % 2_147_483_647
        return Double(state) / 2_147_483_647
    }
}

/// Made-up people for trying the app without granting access, and for screenshots.
enum SampleData {
    static let names = [
        "Anna Bell", "Ben Carter", "Cara Dunn", "Dev Ellis", "Eve Ford", "Finn Grey", "Gail Hart", "Hugo Ives",
        "Isla James", "Jack Kerr", "Kim Lowe", "Liam Moss", "Maya Nash", "Noel Orr", "Orla Pike", "Paul Quinn",
        "Rae Shaw", "Sam Todd", "Tess Usher", "Uma Vance", "Vic Ward", "Wes York", "Zoe Adams", "Abe Birch",
    ]
    static let earlierNames = ["Cleo Dale", "Dan Eccles", "Fay Garner", "Gus Hale", "Ivy Jordan"]

    static func make() -> Dataset {
        var random = Seeded(7)
        let days = 365 * 3 + 120
        let zone = TimeZone.current
        let today = Calendar.current.startOfDay(for: Date())
        let firstDay = today.addingTimeInterval(-Double(days - 1) * 86400)
        _ = zone

        func series(level: Double, from: Int, to: Int, bursts: Int) -> [UInt16] {
            var out = [UInt16](repeating: 0, count: days)
            var centres: [(Double, Double, Double)] = []
            for _ in 0..<bursts {
                centres.append((Double(from) + random.next() * Double(to - from), 15 + random.next() * 70, 0.4 + random.next()))
            }
            for d in from..<to {
                var rate = level * 0.25
                for c in centres { rate += level * c.2 * exp(-pow((Double(d) - c.0) / c.1, 2)) }
                let r = random.next()
                let n = r < 0.55 ? 0.0 : rate * (0.3 + 2.2 * random.next())
                out[d] = UInt16(max(0, n.rounded()))
            }
            return out
        }

        var scored: [Person] = []
        let guesses: [Relationship] = [.partner, .child, .parent, .child, .friend, .parent, .friend, .friend, .colleague, .sibling]
        for (i, name) in names.enumerated() {
            let closeness = pow(1 - Double(i) / Double(names.count), 1.6)
            var p = Person(id: "sample:" + name, name: name)
            let start = i < 10 ? 0 : Int(random.next() * Double(days) * 0.5)
            // Kim's messages stop part-way through, to show the "in memory" treatment.
            let end = i == 10 ? days - 190 : days
            p.daily = series(level: 0.35 + closeness * 4.5, from: start, to: end, bursts: 7)
            let year = p.daily.suffix(365).reduce(0) { $0 + Int($1) }
            p.messages = max(8, year)
            p.outgoing = Int(Double(p.messages) * (0.4 + random.next() * 0.2))
            p.incoming = p.messages - p.outgoing
            p.myReplyMinutes = 2 + random.next() * 40 * (1.3 - closeness)
            p.theirReplyMinutes = 2 + random.next() * 50 * (1.3 - closeness)
            p.calls = Int(closeness * 40 * random.next())
            p.callMinutes = Double(p.calls) * (3 + random.next() * 9)
            p.score = 0.3 + 0.65 * closeness
            p.familySharing = i < 4
            p.guess = i < guesses.count ? guesses[i] : (i % 5 == 0 ? .colleague : .friend)
            scored.append(p)
        }
        var earlier: [Person] = []
        for (i, name) in earlierNames.enumerated() {
            var p = Person(id: "sample:" + name, name: name)
            let from = Int(Double(days) * Double(i) * 0.12), to = from + 200 + Int(random.next() * 260)
            p.daily = series(level: 3, from: from, to: min(days - 380, to), bursts: 3)
            p.messages = p.daily.reduce(0) { $0 + Int($1) }
            earlier.append(p)
        }

        var watch: WatchData?
        if let url = Bundle.main.url(forResource: "SampleWatch", withExtension: "json"), let data = try? Data(contentsOf: url),
           var decoded = try? JSONDecoder().decode(WatchData.self, from: data) {
            // Shift the snapshot so "last ran" reads relative to now.
            let shift = Int(Date().timeIntervalSince1970) - decoded.captured
            decoded.captured += shift
            for i in decoded.views.indices where decoded.views[i].last > 0 { decoded.views[i].last += shift }
            watch = decoded
        }
        return Dataset(scored: scored, earlier: earlier, othersKnown: 694, firstDay: firstDay, days: days, watch: watch, isSample: true)
    }
}
