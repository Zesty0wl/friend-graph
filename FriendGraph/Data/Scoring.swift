import Foundation

/// The closeness score. Pure arithmetic over who messaged whom and when, so it can be tested
/// without touching any database.
///
/// Four parts, each a rank among the owner's own contacts:
///   responsiveness 0.20: how quickly each side replies
///   balance        0.15: whether messages and conversation starts go both ways
///   staying power  0.35: volume, and how many days and weeks the conversation spans
///   depth          0.30: calls, and how much happens outside working hours
/// Thin evidence is pulled toward the middle, and Family Sharing adds a small boost.
enum Scoring {
    struct Event: Sendable {
        var time: Double        // seconds, any epoch, as long as it is consistent
        var outgoing: Bool
    }

    struct Raw: Sendable {
        var events: [Event] = []
        var calls = 0
        var callMinutes = 0.0
        var handles: Set<String> = []
    }

    struct Row: Sendable {
        var key: String
        var count = 0, incoming = 0, outgoing = 0
        var mine: [Double] = [], theirs: [Double] = []
        var balance = 0.0, startBalance = 0.0
        var days = 0, weeks = 0
        var idleDays = 0.0
        var calls = 0, callMinutes = 0.0
        var offHours = 0.0
        var handles: Set<String> = []
        var speed = 0.0, offShrunk = 0.0, volume = 0.0
        var responsive = 0.0, evenness = 0.0, staying = 0.0, depth = 0.0
        var score = 0.0
        var family = false

        var myReplyMinutes: Double? { mine.isEmpty ? nil : Scoring.median(mine) / 60 }
        var theirReplyMinutes: Double? { theirs.isEmpty ? nil : Scoring.median(theirs) / 60 }
    }

    static let conversationGap = 6.0 * 3600     // a silence this long starts a new conversation
    static let replyLimit = 12.0 * 3600         // a switch of direction slower than this is not a reply

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// - Parameters:
    ///   - people: raw events per person, in the order each person first appears.
    ///   - order: person keys in that order (ties in rank are broken by it).
    ///   - family: keys of people in the owner's Family Sharing group.
    ///   - local: turns an event time into local calendar parts.
    static func score(people: [String: Raw], order: [String], family: Set<String>,
                      local: (Double) -> (day: Int, weekday: Int, hour: Int)) -> [Row] {
        var first = Double.infinity, last = -Double.infinity
        for raw in people.values {
            for e in raw.events { first = min(first, e.time); last = max(last, e.time) }
        }
        guard first.isFinite else { return [] }

        var rows: [Row] = []
        for key in order {
            guard let raw = people[key] else { continue }
            let events = raw.events.sorted { $0.time < $1.time }
            let incoming = events.filter { !$0.outgoing }.count, outgoing = events.count - incoming
            guard incoming >= 3, outgoing >= 3 else { continue }      // one-way: notifications, businesses
            var row = Row(key: key)
            var startsMine = 0, startsTheirs = 0
            var previous: Event?
            var days = Set<Int>(), weeks = Set<Int>(), off = 0
            for e in events {
                if let p = previous, e.time - p.time <= conversationGap {
                    if e.outgoing != p.outgoing, e.time - p.time <= replyLimit {
                        if e.outgoing { row.mine.append(e.time - p.time) } else { row.theirs.append(e.time - p.time) }
                    }
                } else if e.outgoing { startsMine += 1 } else { startsTheirs += 1 }
                previous = e
                let parts = local(e.time)
                days.insert(parts.day)
                weeks.insert(Int((e.time - first) / (7 * 86400)))
                // weekday: 1 Sunday ... 7 Saturday
                if parts.weekday == 1 || parts.weekday == 7 || !(9..<18).contains(parts.hour) { off += 1 }
            }
            row.count = events.count; row.incoming = incoming; row.outgoing = outgoing
            row.balance = 1 - abs(Double(incoming - outgoing)) / Double(events.count)
            row.startBalance = 1 - abs(Double(startsMine - startsTheirs)) / Double(max(1, startsMine + startsTheirs))
            row.days = days.count; row.weeks = weeks.count
            row.idleDays = (last - (events.last?.time ?? last)) / 86400
            row.calls = raw.calls; row.callMinutes = raw.callMinutes
            row.offHours = Double(off) / Double(events.count)
            row.handles = raw.handles
            row.family = family.contains(key)
            rows.append(row)
        }
        guard !rows.isEmpty else { return [] }

        // Shrink thin evidence toward the group's middle so three fast replies can't top the chart.
        let allMine = rows.flatMap(\.mine), allTheirs = rows.flatMap(\.theirs)
        let midMine = log(max(1, allMine.isEmpty ? 600 : median(allMine)))
        let midTheirs = log(max(1, allTheirs.isEmpty ? 600 : median(allTheirs)))
        let midOff = median(rows.map(\.offHours))
        func shrunk(_ xs: [Double], _ mid: Double) -> Double {
            guard !xs.isEmpty else { return mid }
            return (Double(xs.count) * log(max(1, median(xs))) + 5 * mid) / (Double(xs.count) + 5)
        }
        for i in rows.indices {
            rows[i].speed = -(shrunk(rows[i].mine, midMine) + shrunk(rows[i].theirs, midTheirs)) / 2
            rows[i].offShrunk = (Double(rows[i].count) * rows[i].offHours + 30 * midOff) / (Double(rows[i].count) + 30)
            rows[i].volume = log(Double(rows[i].count))
        }

        /// Rank of each row for one measure, 0 (lowest) to 1 (highest).
        func rank(_ value: (Row) -> Double) -> [Double] {
            let order = rows.indices.sorted { a, b in
                let va = value(rows[a]), vb = value(rows[b])
                return va == vb ? a < b : va < vb
            }
            var out = [Double](repeating: 0, count: rows.count)
            for (position, index) in order.enumerated() { out[index] = Double(position) / Double(max(1, rows.count - 1)) }
            return out
        }
        let pVolume = rank { $0.volume }, pSpeed = rank { $0.speed }, pBalance = rank { $0.balance }
        let pStarts = rank { $0.startBalance }, pDays = rank { Double($0.days) }, pWeeks = rank { Double($0.weeks) }
        let pCalls = rank { Double($0.calls) }, pCallMinutes = rank { $0.callMinutes }, pOff = rank { $0.offShrunk }
        let pRecent = rank { -$0.idleDays }

        for i in rows.indices {
            rows[i].responsive = pSpeed[i]
            rows[i].evenness = (pBalance[i] + pStarts[i]) / 2
            rows[i].staying = (2 * pVolume[i] + pDays[i] + pWeeks[i] + pRecent[i]) / 5
            rows[i].depth = (2 * pCallMinutes[i] + pCalls[i] + pOff[i]) / 4
            let raw = 0.20 * rows[i].responsive + 0.15 * rows[i].evenness + 0.35 * rows[i].staying + 0.30 * rows[i].depth
            let evidence = Double(rows[i].count) + 5 * Double(rows[i].calls)
            let confidence = evidence / (evidence + 25)
            rows[i].score = confidence * raw + (1 - confidence) * 0.4
            if rows[i].family { rows[i].score = min(1, rows[i].score + 0.10) }
        }
        // Closest first; equal scores keep their original order.
        return rows.enumerated().sorted { a, b in
            a.element.score == b.element.score ? a.offset < b.offset : a.element.score > b.element.score
        }.map(\.element)
    }
}
