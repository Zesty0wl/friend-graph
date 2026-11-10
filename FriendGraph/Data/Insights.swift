import Foundation

/// Everything the panel beside a picture shows. Every number here is worked out directly from the
/// owner's data; the on-device model is only ever asked to turn `facts` into a sentence or two.
struct Panel {
    struct Stat: Identifiable {
        var value: String, label: String
        var id: String { label }
    }
    struct Bar: Identifiable {
        var label: String, value: Double, text: String
        var colour = Pal.amber
        var id: String { label }
    }

    var title: String
    var subtitle: String
    var accent = Pal.amber
    /// Identifies the story so it is only written once. Nil when there is nothing to say.
    var storyKey: String?
    var facts: [String] = []
    /// Used when the model is unavailable, and until its sentence arrives.
    var fallback = ""
    /// When true the fallback is always used. For anyone in memory, the words are ours, not a model's.
    var fixedStory = false
    var stats: [Stat] = []
    var split: (mine: Int, theirs: Int)?
    var replies: (mine: Double?, theirs: Double?)?
    var months: [Double] = []
    var monthLabels: [String] = []
    var weekdays: [Double] = []
    var rankingTitle = ""
    var ranking: [Bar] = []
    var rows: [Detail.Row] = []
}

@MainActor
enum Insights {
    // MARK: Per-person arithmetic

    private static func date(_ day: Int, _ data: Dataset) -> Date { data.firstDay.addingTimeInterval(Double(day) * 86400 + 43200) }

    private static func total(_ p: Person) -> Int { p.daily.reduce(0) { $0 + Int($1) } }

    private static func longestStreak(_ p: Person) -> Int {
        var best = 0, run = 0
        for c in p.daily { if c > 0 { run += 1; best = max(best, run) } else { run = 0 } }
        return best
    }

    private static func daysTalked(_ p: Person, last: Int) -> Int { p.daily.suffix(last).filter { $0 > 0 }.count }

    /// Twelve roughly month-long buckets ending today, with the month each falls in.
    private static func months(_ rows: [[UInt16]], _ data: Dataset) -> ([Double], [String]) {
        var values: [Double] = [], labels: [String] = []
        for m in 0..<12 {
            let hi = data.days - Int(Double(11 - m) * 30.44), lo = hi - 30
            var sum = 0.0
            for row in rows { for d in max(0, lo)..<max(0, min(row.count, hi)) { sum += Double(row[d]) } }
            values.append(sum)
            labels.append(String(date(max(0, hi - 15), data).formatted(.dateTime.month(.narrow))))
        }
        return (values, labels)
    }

    /// Messages by day of the week over the past year, Monday first.
    private static func weekdays(_ rows: [[UInt16]], _ data: Dataset) -> [Double] {
        var out = [Double](repeating: 0, count: 7)
        let start = max(0, data.days - 365)
        let firstWeekday = Calendar.current.component(.weekday, from: date(start, data))      // 1 is Sunday
        for row in rows {
            for d in start..<min(row.count, data.days) where row[d] > 0 {
                out[(firstWeekday + (d - start) + 5) % 7] += Double(row[d])
            }
        }
        return out
    }

    private static let dayNames = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

    private static func busiestDay(_ week: [Double]) -> String? {
        guard let top = week.max(), top > 0, let i = week.firstIndex(of: top) else { return nil }
        return dayNames[i]
    }

    private static func short(_ minutes: Double?) -> String {
        guard let m = minutes else { return "–" }
        if m < 1 { return "<1 min" }
        if m < 90 { return "\(Int(m.rounded())) min" }
        return "\(Int((m / 60).rounded())) hr"
    }

    // MARK: A person

    static func person(_ p: Person, subtitle: String, model: AppModel) -> Panel? {
        guard let data = model.dataset else { return nil }
        let decisions = model.decisions, first = p.first
        var panel = Panel(title: p.name, subtitle: subtitle)
        let allTime = max(total(p), p.messages)
        let since = p.firstActiveDay.map { date($0, data).formatted(.dateTime.year()) }

        if decisions.standing(of: p) == .inMemory {
            panel.accent = Pal.memory
            panel.storyKey = "memory:" + p.id
            panel.fixedStory = true
            panel.fallback = "\(first) keeps a place in my circle."
            panel.stats = [.init(value: allTime.formatted(), label: "messages between us")]
            if let since { panel.stats.append(.init(value: since, label: "talking since")) }
            if p.calls > 0 { panel.stats.append(.init(value: "\(Int((p.callMinutes / 60).rounded(.up)))", label: p.callMinutes >= 90 ? "hours on calls this year" : "hour on calls this year")) }
            let (values, labels) = months([p.daily], data)
            panel.months = values; panel.monthLabels = labels
            return panel
        }

        let streak = longestStreak(p), talked = daysTalked(p, last: 365), week = weekdays([p.daily], data)
        panel.stats = [.init(value: p.messages.formatted(), label: "messages this year"),
                       .init(value: "\(talked)", label: "days we talked this year")]
        if let since { panel.stats.append(.init(value: since, label: "talking since")) }
        if streak > 1 { panel.stats.append(.init(value: "\(streak)", label: "days in a row, our record")) }
        if p.calls > 0 { panel.stats.append(.init(value: "\(p.calls)", label: "calls, \(Int(p.callMinutes.rounded())) minutes in all")) }
        if allTime > p.messages * 2 { panel.stats.append(.init(value: allTime.formatted(), label: "messages, all time")) }
        panel.split = (p.outgoing, p.incoming)
        panel.replies = (p.myReplyMinutes, p.theirReplyMinutes)
        let (values, labels) = months([p.daily], data)
        panel.months = values; panel.monthLabels = labels
        panel.weekdays = week

        // What the story may draw on, most interesting first. Each is a complete sentence in the owner's
        // voice, so the first two also serve as the story when the model is not available.
        let relation = decisions.relationship(of: p)
        var facts: [String] = []
        if let mine = p.myReplyMinutes, let theirs = p.theirReplyMinutes {
            if theirs < mine * 0.6 { facts.append("\(first) replies to me faster than I reply to them: about \(minutesText(theirs)), against my \(minutesText(mine)).") }
            else if mine < theirs * 0.6 { facts.append("I reply to \(first) faster than they reply to me: about \(minutesText(mine)), against their \(minutesText(theirs)).") }
            else { facts.append("\(first) and I reply to each other at about the same pace, around \(minutesText((mine + theirs) / 2)).") }
        }
        if let day = busiestDay(week) { facts.append("\(first) and I talk most on \(day).") }
        if streak >= 5 { facts.append("Our longest unbroken run is \(streak) days in a row.") }
        facts.append("We exchanged \(p.messages.formatted()) messages this year, on \(talked) different days.")
        if let since { facts.append("Our messages go back to \(since).") }
        if p.calls > 0 { facts.append("We had \(p.calls) calls this year.") }
        let share = Double(p.outgoing) / Double(max(1, p.messages))
        if share > 0.58 { facts.append("I send more of the messages than \(first) does.") } else if share < 0.42 { facts.append("\(first) sends more of the messages than I do.") }
        panel.facts = facts
        panel.storyKey = "person:\(p.id):\(p.messages):\(relation.rawValue)"
        panel.fallback = facts.prefix(2).joined(separator: " ")
        return panel
    }

    // MARK: Each picture as a whole

    static func overview(_ tab: Tab, model: AppModel) -> Panel? {
        guard let data = model.dataset else { return nil }
        switch tab {
        case .circle: return circle(model, data)
        case .journey: return journey(model, data)
        case .year: return year(model, data)
        case .iris: return iris(data)
        }
    }

    private static func circle(_ model: AppModel, _ data: Dataset) -> Panel {
        let people = model.circlePeople, living = people.filter { model.decisions.standing(of: $0) != .inMemory }
        var panel = Panel(title: "My circle", subtitle: "Nearer and warmer means closer. Drag to spin it, drag someone to another ring, and point at anyone to see the two of us.")
        let messages = people.reduce(0) { $0 + $1.messages }, callHours = people.reduce(0) { $0 + $1.callMinutes } / 60
        let earliest = people.compactMap { $0.firstActiveDay }.min().map { date($0, data).formatted(.dateTime.year()) }
        panel.stats = [.init(value: "\(people.count)", label: "people I really talk to"),
                       .init(value: messages.formatted(), label: "messages this year")]
        if callHours >= 1 { panel.stats.append(.init(value: "\(Int(callHours.rounded()))", label: "hours on calls")) }
        if let earliest { panel.stats.append(.init(value: earliest, label: "as far back as it goes")) }

        let top = people.sorted { $0.messages > $1.messages }.prefix(5)
        let most = Double(max(1, top.first?.messages ?? 1))
        panel.rankingTitle = "Most messages"
        panel.ranking = top.enumerated().map { i, p in
            .init(label: p.first, value: Double(p.messages) / most, text: p.messages.formatted(), colour: Pal.series[i * 2 % Pal.series.count])
        }
        let week = weekdays(people.map(\.daily), data)
        panel.weekdays = week

        var facts: [String] = []
        if let quick = living.filter({ $0.theirReplyMinutes != nil && $0.messages >= 40 }).min(by: { $0.theirReplyMinutes! < $1.theirReplyMinutes! }) {
            facts.append("\(quick.first) is the quickest to reply to me, usually in about \(minutesText(quick.theirReplyMinutes)).")
        }
        if let busiest = top.first { facts.append("I exchange more messages with \(busiest.first) than with anyone else.") }
        let inner = people.prefix(5).reduce(0) { $0 + $1.messages }
        if messages > 0, people.count > 5 { facts.append("\(Int((Double(inner) / Double(messages) * 100).rounded())) percent of my messages are with my five closest people.") }
        if let day = busiestDay(week) { facts.append("My busiest day for messages is \(day).") }
        if let runner = living.max(by: { longestStreak($0) < longestStreak($1) }), longestStreak(runner) >= 7 {
            facts.append("My longest unbroken run with one person is \(longestStreak(runner)) days in a row, with \(runner.first).")
        }
        if let mine = living.filter({ $0.myReplyMinutes != nil && $0.messages >= 40 }).min(by: { $0.myReplyMinutes! < $1.myReplyMinutes! }) {
            facts.append("The person I reply to fastest is \(mine.first).")
        }
        panel.facts = facts
        panel.storyKey = "circle:\(people.count):\(messages)"
        panel.fallback = facts.prefix(2).joined(separator: " ")
        return panel
    }

    private static func journey(_ model: AppModel, _ data: Dataset) -> Panel {
        let people = model.circlePeople, earlier = model.earlierPeople, everyone = people + earlier
        var panel = Panel(title: "My year, and who was alongside", subtitle: "I'm the bright dot. People move in close during the weeks we talked, and drift out when we didn't. Drag to move through time.")
        let all = everyone.reduce(0) { $0 + total($1) }
        let years = max(1, Int((Double(data.days) / 365.25).rounded()))
        // The busiest month across everyone.
        var byMonth: [String: Int] = [:], monthOrder: [String] = []
        for p in everyone {
            for (d, c) in p.daily.enumerated() where c > 0 {
                let key = date(d, data).formatted(.dateTime.month(.wide).year())
                if byMonth[key] == nil { monthOrder.append(key) }
                byMonth[key, default: 0] += Int(c)
            }
        }
        let busiest = monthOrder.max { byMonth[$0]! < byMonth[$1]! }
        panel.stats = [.init(value: "\(years)", label: years == 1 ? "year of history" : "years of history"),
                       .init(value: all.formatted(), label: "messages in all")]
        if let busiest { panel.stats.append(.init(value: busiest, label: "my busiest month")) }
        if !earlier.isEmpty { panel.stats.append(.init(value: "\(earlier.count)", label: "people from earlier years")) }

        let lasting = people.filter { model.decisions.standing(of: $0) != .inMemory }
            .map { ($0, $0.daily.filter { $0 > 0 }.count) }.sorted { $0.1 > $1.1 }.prefix(5)
        let most = Double(max(1, lasting.first?.1 ?? 1))
        panel.rankingTitle = "Days we talked, all time"
        panel.ranking = lasting.enumerated().map { i, entry in
            .init(label: entry.0.first, value: Double(entry.1) / most, text: entry.1.formatted(), colour: Pal.series[i * 2 % Pal.series.count])
        }
        let (values, labels) = months(everyone.map(\.daily), data)
        panel.months = values; panel.monthLabels = labels

        var facts: [String] = []
        if let longest = lasting.first { facts.append("\(longest.0.first) is the person I have talked to on the most days, \(longest.1.formatted()) in all.") }
        if let busiest { facts.append("My busiest month for messages was \(busiest).") }
        if !earlier.isEmpty { facts.append("\(earlier.count) people I once talked to a great deal are no longer among my closest.") }
        facts.append("My history on this Mac covers about \(years) \(years == 1 ? "year" : "years") and \(all.formatted()) messages.")
        panel.facts = facts
        panel.storyKey = "journey:\(all):\(everyone.count)"
        panel.fallback = facts.prefix(2).joined(separator: " ")
        return panel
    }

    private static func year(_ model: AppModel, _ data: Dataset) -> Panel {
        let people = Array(model.circlePeople.prefix(10))
        var panel = Panel(title: "A year with my circle", subtitle: "One line per person, closest at the top. It swells in the weeks we talked most and thins out when we went quiet. Point at a line for the two of us.")
        let start = max(0, data.days - 53 * 7)
        var weekTotals = [Int](repeating: 0, count: 53)
        var talkedWeeks: [(Person, Int)] = []
        for p in people {
            var weeks = 0
            for w in 0..<53 {
                var sum = 0
                for d in (start + w * 7)..<min(data.days, start + (w + 1) * 7) where d < p.daily.count { sum += Int(p.daily[d]) }
                weekTotals[w] += sum
                if sum > 0 { weeks += 1 }
            }
            talkedWeeks.append((p, weeks))
        }
        let total = weekTotals.reduce(0, +)
        let busiestWeek = weekTotals.indices.max { weekTotals[$0] < weekTotals[$1] } ?? 0
        let busiestDate = date(start + busiestWeek * 7, data).formatted(.dateTime.day().month(.abbreviated))
        panel.stats = [.init(value: total.formatted(), label: "messages in 53 weeks"),
                       .init(value: "\(total / 53)", label: "a week, on average"),
                       .init(value: busiestDate, label: "start of my busiest week"),
                       .init(value: weekTotals[busiestWeek].formatted(), label: "messages that week")]
        let ranked = talkedWeeks.filter { model.decisions.standing(of: $0.0) != .inMemory }.sorted { $0.1 > $1.1 }.prefix(5)
        panel.rankingTitle = "Weeks we talked, of 53"
        panel.ranking = ranked.map { entry in
            let index = people.firstIndex { $0.id == entry.0.id } ?? 0
            return .init(label: entry.0.first, value: Double(entry.1) / 53, text: "\(entry.1)", colour: Pal.series[index % Pal.series.count])
        }
        panel.weekdays = weekdays(people.map(\.daily), data)

        var facts: [String] = []
        if let steady = ranked.first { facts.append("\(steady.0.first) and I talked in \(steady.1) of the last 53 weeks, more than anyone else.") }
        facts.append("My busiest week began on \(busiestDate), with \(weekTotals[busiestWeek].formatted()) messages.")
        if let day = busiestDay(panel.weekdays) { facts.append("My messages peak on \(day).") }
        facts.append("Over 53 weeks I exchanged \(total.formatted()) messages with my ten closest people, about \(total / 53) a week.")
        panel.facts = facts
        panel.storyKey = "year:\(total):\(people.count)"
        panel.fallback = facts.prefix(2).joined(separator: " ")
        return panel
    }

    private static func iris(_ data: Dataset) -> Panel? {
        guard let watch = data.watch else { return nil }
        var panel = Panel(title: "What my Mac is working out about me", subtitle: "Every strand is one thing macOS keeps up to date. Longer strands draw on more sources, brighter ones ran more recently, and a bigger dot at the tip holds more. A hollow tip is empty. Point at a strand to read it.")
        let hour = watch.views.filter { $0.last > 0 && watch.captured - $0.last < 3600 }.count
        let day = watch.views.filter { $0.last > 0 && watch.captured - $0.last < 86400 }.count
        let empty = watch.views.filter { $0.rows == 0 }.count
        let streams = Set(watch.views.flatMap { $0.listens.filter { $0.type == "biome" }.map(\.ref) }).count
        panel.stats = [.init(value: "\(watch.views.count)", label: "things kept up to date"),
                       .init(value: "\(hour)", label: "updated in the last hour"),
                       .init(value: "\(empty)", label: "hold nothing on this Mac"),
                       .init(value: "\(streams)", label: "live activity streams feeding them")]
        var counts: [Int: Int] = [:]
        for v in watch.views { counts[v.cat, default: 0] += 1 }
        let ordered = counts.sorted { $0.value > $1.value }
        let most = Double(max(1, ordered.first?.value ?? 1))
        panel.rankingTitle = "What they are about"
        panel.ranking = ordered.map { cat, n in
            .init(label: watch.cats[min(cat, watch.cats.count - 1)], value: Double(n) / most, text: "\(n)", colour: Pal.categories[min(cat, Pal.categories.count - 1)])
        }
        let names = ordered.prefix(3).map { cat, n in "\(n) are about \(watch.cats[min(cat, watch.cats.count - 1)] == "Siri and Apple Intelligence" ? "Siri and Apple Intelligence" : watch.cats[min(cat, watch.cats.count - 1)].lowercased())" }
        var facts = ["My Mac keeps \(watch.views.count) separate things up to date about me, and \(hour) of them were updated in the last hour."]
        if names.count == 3 { facts.append("Of those, \(names[0]), \(names[1]) and \(names[2]).") }
        if empty > 0 { facts.append("\(empty) of them hold nothing on this Mac.") }
        facts.append("They are fed by \(streams) live streams of what I do on my devices.")
        panel.facts = facts
        panel.storyKey = "iris:\(watch.views.count):\(hour / 5)"
        panel.fallback = facts.prefix(2).joined(separator: " ")
        return panel
    }

    /// A strand of the iris: the facts as they are, no story.
    static func strand(_ detail: Detail) -> Panel {
        var panel = Panel(title: detail.title, subtitle: detail.subtitle)
        panel.rows = detail.rows
        return panel
    }
}
