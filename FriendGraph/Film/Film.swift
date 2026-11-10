import SwiftUI

/// "My year": a 30 second film in six chapters, drawn frame by frame. It reuses the app's own
/// pictures, so the film shows exactly what the owner has already seen and confirmed.
@MainActor
final class Film {
    /// What the owner told us before the film was made. All optional.
    struct Answers: Equatable {
        var word = ""
        var thanks: String?          // a person's id
        var moment = ""
    }

    static let size = CGSize(width: 1080, height: 1920)
    static let fps = 30
    static let length = 30.0
    /// Title, numbers, closest people, busiest week, one person, close.
    static let starts: [Double] = [0, 4, 8, 15, 20, 25.5]
    /// In the "closest people" chapter, one person arrives every `arrivalGap` seconds, each on a note.
    static let firstArrival = 0.3, arrivalGap = 0.22

    /// A moment where something appears on screen, so the music can play a note at the same instant.
    /// `step` picks the note from the chapter's chord: higher steps are higher notes.
    struct Cue { var time: Double; var step: Int; var level: Double }

    /// Every such moment in the film, in order. The drawing code below uses the same timings.
    static func cues(script: Script, arrivals: Int) -> [Cue] {
        var cues: [Cue] = []
        func add(_ chapter: Int, _ local: Double, _ step: Int, _ level: Double = 1) { cues.append(Cue(time: starts[chapter] + local, step: step, level: level)) }
        // Title: three rings start, the title lands, then the word.
        add(0, 0.05, 0); add(0, 0.40, 2); add(0, 0.75, 4); add(0, 1.10, 5, 1.2); add(0, 2.0, 7, 1.1)
        // Numbers: each arrives, then settles on its final figure.
        for i in 0..<min(3, script.numbers.count) { add(1, Double(i) * 0.7, i * 2, 1.2); add(1, Double(i) * 0.7 + 1.5, i * 2 + 5, 0.7) }
        // Closest people: one note per arrival, the inner circle brightest.
        let walk = [0, 2, 4, 1, 3]
        for k in 0..<arrivals { add(2, firstArrival + Double(k) * arrivalGap, walk[k % 5] + (k < 5 ? 5 : k < 11 ? 0 : 0), k < 5 ? 1.15 : k < 11 ? 0.9 : 0.7) }
        add(2, captionDelay(arrivals), 0, 0.9)
        // Week by week: a rising run as the ribbons sweep across.
        for j in 0..<5 { add(3, 2.6 * Double(j) / 4, j + 1) }
        add(3, 3.0, 0, 0.9)
        // One person: the portrait, three lines about them, then the caption.
        add(4, 0.05, 0, 1.3); add(4, 0.9, 2); add(4, 1.35, 3); add(4, 1.8, 4); add(4, 2.4, 6, 0.9)
        // Close: the owner's words if there are any, then the sign-off.
        let quote = script.moment.isEmpty ? 0.0 : 2.6
        add(5, 0.05, 0, 1.1)
        if quote > 0 { add(5, quote, 2) }
        add(5, quote + 0.35, 4); add(5, quote + 0.7, 7, 1.2)
        return cues
    }

    static func captionDelay(_ arrivals: Int) -> Double { firstArrival + Double(arrivals) * arrivalGap + 0.25 }

    struct Script {
        var year: String
        var word: String
        var moment: String
        var numbers: [(value: Int, label: String)]
        var circleFacts: [String]
        var yearFacts: [String]
        var person: Person?
        var personLines: [String]
        var personFacts: [String]
        var thanking: Bool
    }

    let script: Script
    /// One caption per chapter; empty where the chapter speaks for itself.
    var captions: [String]
    private let options: DrawOptions
    private let circleScene: CircleScene?
    let arrivals: Int
    private let closing: CircleScene?
    private let year: YearScene?
    private let face: Face?
    private var time = 0.0
    private var stars: [(Double, Double, Double)] = []

    /// Works out what the film will say, before any captions are written.
    static func script(model: AppModel, answers: Answers) -> Script {
        let people = model.circlePeople, data = model.dataset
        let living = people.filter { model.decisions.standing(of: $0) != .inMemory }
        let messages = people.reduce(0) { $0 + $1.messages }, hours = Int((people.reduce(0) { $0 + $1.callMinutes } / 60).rounded())
        var numbers: [(Int, String)] = [(messages, "messages"), (people.count, "people I really talk to")]
        if hours >= 2 { numbers.append((hours, "hours on calls")) } else {
            numbers.append((Set(people.flatMap { p in p.daily.suffix(365).enumerated().filter { $0.element > 0 }.map(\.offset) }).count, "days I talked to someone"))
        }
        // The person in the spotlight: whoever the owner wants to thank, or failing that the closest.
        let thanked = answers.thanks.flatMap { id in living.first { $0.id == id } }
        let person = thanked ?? living.first
        var lines: [String] = [], facts: [String] = []
        if let person, let panel = Insights.person(person, subtitle: "", model: model) {
            lines = panel.stats.prefix(3).map { $0.label == "talking since" ? "talking since \($0.value)" : "\($0.value) \($0.label)" }
            facts = panel.facts
        }
        let last = data.map { $0.firstDay.addingTimeInterval(Double($0.days - 1) * 86400) } ?? Date()
        return Script(year: last.formatted(.dateTime.year()), word: String(answers.word.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)),
                      moment: String(answers.moment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90)),
                      numbers: numbers, circleFacts: Insights.overview(.circle, model: model)?.facts ?? [],
                      yearFacts: Insights.overview(.year, model: model)?.facts ?? [], person: person, personLines: lines, personFacts: facts,
                      thanking: thanked != nil)
    }

    init(model: AppModel, script: Script, captions: [String], options: DrawOptions) {
        self.script = script
        self.captions = captions
        self.options = options
        arrivals = min(18, model.circlePeople.count)
        circleScene = model.dataset.map { CircleScene(people: model.circlePeople, decisions: model.decisions, scoredCount: $0.scored.count, othersKnown: $0.othersKnown,
                                                      firstBirth: Self.firstArrival, stagger: Self.arrivalGap) }
        closing = SceneBuilder.make(.circle, model: model, live: false) as? CircleScene
        year = SceneBuilder.make(.year, model: model, live: false) as? YearScene
        face = script.person.map { Face($0, model.decisions) }
        // The closing circle should already be settled when it appears.
        if let closing { for _ in 0..<540 { closing.advance(by: 1.0 / 60) } }
        var random = Seeded(53)
        for _ in 0..<70 { stars.append((random.next() * 1080, random.next() * 1920, 0.3 + random.next() * 0.7)) }
    }

    private func chapter(at t: Double) -> Int { Self.starts.lastIndex { $0 <= t } ?? 0 }
    private func end(of chapter: Int) -> Double { chapter + 1 < Self.starts.count ? Self.starts[chapter + 1] : Self.length }

    func advance(by dt: Double) {
        time += dt
        switch chapter(at: time) {
        case 2: circleScene?.advance(by: dt)
        case 3: year?.advance(by: dt)
        case 5: closing?.advance(by: dt)
        default: break
        }
    }

    // MARK: Drawing

    private func ease(_ x: Double) -> Double { let u = max(0, min(1, x)); return 1 - pow(1 - u, 3) }

    /// Centred, wrapped text: lines are broken by measuring, then each is drawn centred. Returns the height it took.
    @discardableResult
    private func words(_ p: Painter, _ string: String, y: Double, style: TextStyle, colour: RGBA, width: Double = 900) -> Double {
        var lines: [String] = [], current = ""
        for word in string.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if p.measure(candidate, style).width > width, !current.isEmpty { lines.append(current); current = word } else { current = candidate }
        }
        if !current.isEmpty { lines.append(current) }
        let lineHeight = p.measure("Ag", style).height * 1.12
        for (i, line) in lines.enumerated() { p.text(line, 540, y + Double(i) * lineHeight, style, colour, anchor: .top) }
        return Double(lines.count) * lineHeight
    }

    func paint(_ p: Painter) {
        let t = time, index = chapter(at: t), local = t - Self.starts[index], span = end(of: index) - Self.starts[index]
        for s in stars {
            let drift = s.1 - t * 6 * s.2
            p.rect(s.0, drift.truncatingRemainder(dividingBy: 1920) + (drift < 0 ? 1920 : 0), 2, 2, Pal.paper.c(0.06 + 0.12 * s.2))
        }
        // Each chapter fades in and out, so the cuts are soft.
        let fade = min(1, local / 0.55) * (index == Self.starts.count - 1 ? 1 : min(1, (span - local) / 0.45))
        p.save()
        p.opacity = max(0, min(1, fade))
        switch index {
        case 0: title(p, local)
        case 1: numbers(p, local)
        case 2: closest(p, local)
        case 3: busiest(p, local)
        case 4: spotlight(p, local)
        default: close(p, local, span)
        }
        p.restore()
        // The same quiet marks on every frame.
        p.text("MY YEAR · \(script.year)", 540, 120, .sans(26, .medium, tracking: 4), Pal.quiet.c())
        p.text("FRIEND GRAPH", 540, 1820, .sans(24, tracking: 5), Pal.quiet.c(0.8))
        // The last second fades to black.
        let out = max(0, min(1, (t - (Self.length - 0.9)) / 0.9))
        if out > 0 { p.rect(0, 0, 1080, 1920, Pal.ground.c(out)) }
    }

    private func rings(_ p: Painter, x: Double, y: Double, scale: Double, drawn: Double, t: Double) {
        p.additive = true
        p.glow(x, y, 330 * scale, Pal.amber, 0.16)
        p.additive = false
        for (i, colour) in [Pal.amber, Pal.rose, Pal.violet].enumerated() {
            let r = (95 + Double(i) * 62) * scale, sweep = TAU * ease(drawn - Double(i) * 0.22)
            guard sweep > 0.01 else { continue }
            let start = -Double.pi / 2 + t * (0.5 - Double(i) * 0.14)
            p.ring(x, y, r, width: (9 - Double(i) * 1.6) * scale, colour.c(0.95), from: start, sweep: sweep, round: true)
            // a friend on each ring
            let a = start + sweep
            p.disc(x + cos(a) * r, y + sin(a) * r, (15 - Double(i) * 1.5) * scale, Pal.ground.c())
            p.disc(x + cos(a) * r, y + sin(a) * r, (11 - Double(i) * 1.5) * scale, colour.c())
        }
        p.disc(x, y, 34 * scale * ease(drawn * 2), Pal.core.c())
    }

    private func title(_ p: Painter, _ u: Double) {
        rings(p, x: 540, y: 700, scale: 1.25, drawn: u / 1.6, t: u)
        p.save()
        p.opacity *= ease((u - 1.1) / 0.5)
        p.text("My year", 540, 1180, .serif(170), Pal.paper.c())
        p.restore()
        p.save()
        p.opacity *= ease((u - 2.0) / 0.5)
        if script.word.isEmpty {
            p.text("and who was in it", 540, 1330, .serif(58), Pal.soft.c())
        } else {
            p.text("in a word", 540, 1318, .sans(30, tracking: 4), Pal.quiet.c())
            p.text(script.word, 540, 1420, .serif(110), Pal.amber.c())
        }
        p.restore()
    }

    private func numbers(_ p: Painter, _ u: Double) {
        let colours = [Pal.amber, Pal.rose, Pal.violet]
        for (i, item) in script.numbers.prefix(3).enumerated() {
            let appear = (u - Double(i) * 0.7) / 0.6
            guard appear > 0 else { continue }
            p.save()
            p.opacity *= ease(appear)
            let y = 470 + Double(i) * 390 + (1 - ease(appear)) * 40
            let shown = Int((Double(item.value) * ease((u - Double(i) * 0.7) / 1.5)).rounded())
            let landed = u - Double(i) * 0.7 - 1.5, pop = landed > 0 ? 1 + 0.07 * exp(-landed * 7) : 1       // a small bump as the count settles, on its note
            p.save(); p.translate(540, y); p.scale(pop)
            p.text(shown.formatted(), 0, 0, .serif(210), colours[i].c())
            p.restore()
            p.text(item.label, 540, y + 150, .sans(40), Pal.soft.c())
            p.restore()
        }
    }

    private func picture(_ p: Painter, _ scene: any VisualScene, top: Double, width: Double) {
        p.save()
        let scale = width / scene.designSize.width
        p.translate((1080 - width) / 2, top)
        p.scale(scale)
        p.clip(CGRect(origin: .zero, size: scene.designSize))
        scene.paint(p, options)
        p.restore()
    }

    private func caption(_ p: Painter, _ text: String, y: Double, after u: Double) {
        guard !text.isEmpty else { return }
        p.save()
        p.opacity *= ease(u / 0.8)
        words(p, text, y: y + (1 - ease(u / 0.8)) * 30, style: .serif(60), colour: Pal.paper.c())
        p.restore()
    }

    private func closest(_ p: Painter, _ u: Double) {
        p.text("THE PEOPLE CLOSEST TO ME", 540, 250, .sans(30, .medium, tracking: 5), Pal.amber.c())
        if let circleScene { picture(p, circleScene, top: 300, width: 1060) }
        caption(p, captions[2], y: 1420, after: u - Self.captionDelay(arrivals))
    }

    private func busiest(_ p: Painter, _ u: Double) {
        p.text("WEEK BY WEEK", 540, 250, .sans(30, .medium, tracking: 5), Pal.rose.c())
        if let year { picture(p, year, top: 350, width: 1060) }
        caption(p, captions[3], y: 1400, after: u - 3.0)
    }

    private func spotlight(_ p: Painter, _ u: Double) {
        guard let face else { return }
        let colour = face.standing == .inMemory ? Pal.memory : Pal.amber, x = 540.0, y = 640.0, r = 200.0 * (0.9 + 0.1 * ease(u / 0.9))
        p.text(script.thanking ? "THANK YOU" : "CLOSEST OF ALL", 540, 250, .sans(30, .medium, tracking: 5), colour.c())
        p.additive = true
        p.glow(x, y, r + 150, colour, 0.22 + 0.04 * sin(u * 2))
        p.additive = false
        p.portrait(face, x: x, y: y, r: r, colour: colour, options: options)
        p.ring(x, y, r + 14, width: 5, colour.c(0.9))
        // messages circling in
        p.additive = true
        for k in 0..<5 {
            let a = u * 0.9 + Double(k) * TAU / 5
            p.glow(x + cos(a) * (r + 14), y + sin(a) * (r + 14), 16, RGB(255, 240, 215), 0.9)
        }
        p.additive = false
        if let name = face.label(options.names == .full ? .full : .first) {
            // Full names can be long, so the size steps down to keep them on one line.
            p.text(name, 540, 965, .serif(name.count > 16 ? 76 : name.count > 11 ? 96 : 120), Pal.paper.c())
        }
        for (i, line) in script.personLines.enumerated() {
            p.save()
            p.opacity *= ease((u - 0.9 - Double(i) * 0.45) / 0.6)
            p.text(line, 540, 1100 + Double(i) * 66, .sans(40), Pal.soft.c())
            p.restore()
        }
        caption(p, captions[4], y: 1380, after: u - 2.4)
    }

    private func close(_ p: Painter, _ u: Double, _ span: Double) {
        if let closing {
            p.save()
            picture(p, closing, top: 300, width: 1060)
            p.restore()
            p.rect(0, 280, 1080, 1100, Pal.ground.c(0.45))          // sit the circle back behind the words
        }
        // The owner's own words first, if they gave us some, then the sign-off.
        let quoteTime = script.moment.isEmpty ? 0 : 2.6
        p.save()
        if u < quoteTime {
            p.opacity *= min(1, u / 0.6) * min(1, (quoteTime - u) / 0.5)
            p.text("THE BEST OF IT", 540, 1400, .sans(28, .medium, tracking: 5), Pal.amber.c())
            words(p, "“" + script.moment + "”", y: 1450, style: .serif(62), colour: Pal.paper.c())
        } else {
            p.opacity *= ease((u - quoteTime - 0.35) / 0.6)
            p.text("That was my year.", 540, 1500, .serif(96), Pal.paper.c())
        }
        p.restore()
    }
}
