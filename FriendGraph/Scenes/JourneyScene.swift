import SwiftUI

/// My year, and who was alongside: I travel forward through every day the Mac remembers, and
/// people move in close during the weeks we talked and drift out when we didn't.
final class JourneyScene: VisualScene {
    let designSize = CGSize(width: 600, height: 540)
    private let width = 600.0, height = 540.0
    private let pxPerDay = 30.0 / 7, cx = 476.0, cy = 296.0, far = 190.0, trail = 104.0
    private let faces: [Face]
    private let counts: [[UInt16]]
    private let n: Int
    private var level: [[Float]] = []           // smoothed closeness per person per day, 0 to 1
    private var clockTable: [Double] = [0]      // playback seconds at the start of each day
    private var last: [Int] = []
    private var lanes: [Int] = []
    private let memory: [Bool]
    private let firstDay: Date
    private var stars: [(Double, Double, Double)] = []
    private var play = 0.0
    private var held = false
    private var lastPointerX = 0.0
    private var wall = 0.0
    /// How far each face is currently moved to keep clear of its neighbours.
    private var shift: [Double] = []

    init(cast: [Person], leading: Int, decisions: Decisions, firstDay: Date, days: Int) {
        faces = cast.map { Face($0, decisions) }
        counts = cast.map { $0.daily.count == days ? $0.daily : [UInt16](repeating: 0, count: days) }
        memory = faces.map { $0.standing == .inMemory }
        self.firstDay = firstDay
        n = max(2, days)

        // Closeness per day: a wide bell-shaped average, so one busy day doesn't snap someone in and out.
        let reach = 36
        var kernel = (-reach...reach).map { exp(-Double($0 * $0) / (2 * 13 * 13)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        level = counts.map { row in
            var out = [Float](repeating: 0, count: n)
            guard let lo = row.firstIndex(where: { $0 > 0 }), let hi = row.lastIndex(where: { $0 > 0 }) else { return out }
            for i in max(0, lo - reach)...min(n - 1, hi + reach) {
                var e = 0.0
                for j in -reach...reach {
                    let k = i + j
                    if k >= 0 && k < row.count && row[k] > 0 { e += Double(row[k]) * kernel[j + reach] }
                }
                out[i] = Float(min(1, sqrt(e * 7) / 9))
            }
            return out
        }
        last = counts.map { $0.lastIndex(where: { $0 > 0 }) ?? 0 }

        // Playback clock: about 30 days a second, racing through stretches where nobody is around.
        var speed = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for row in level { sum += row[i] }
            speed[i] = sum > 0.03 ? 1.0 / 30 : 1.0 / 500
        }
        var prefix = [0.0]
        for v in speed { prefix.append(prefix.last! + v) }
        for i in 0..<n {
            let lo = max(0, i - 25), hi = min(n - 1, i + 25)
            clockTable.append(clockTable[i] + (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1))
        }

        // Lanes: today's closest each keep a lane of their own; people from earlier years take the
        // nearest lane that has been free for four months, so the screen never holds more than a handful.
        var busy: [Int] = []
        lanes = [Int](repeating: 0, count: cast.count)
        let firsts = counts.map { $0.firstIndex(where: { $0 > 0 }) ?? 0 }
        for p in cast.indices.sorted(by: { a, b in
            if (a >= leading) != (b >= leading) { return b >= leading }
            return firsts[a] == firsts[b] ? a < b : firsts[a] < firsts[b]
        }) {
            let free = busy.firstIndex { $0 + 120 < firsts[p] }
            if p < leading || free == nil { lanes[p] = busy.count; busy.append(last[p]) } else { lanes[p] = free!; busy[free!] = last[p] }
        }
        var random = Seeded(71)
        for _ in 0..<90 { stars.append((random.next() * 2000, random.next() * height, 0.3 + random.next() * 0.7)) }
    }

    var footer: String { "Every day, as far back as my messages go. Drag to move through time." }

    private var period: Double { clockTable[n] + 2.5 }

    private func day(at seconds: Double) -> Double {
        let t = seconds.truncatingRemainder(dividingBy: period)
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if clockTable[mid + 1] <= t { lo = mid + 1 } else { hi = mid }
        }
        if lo >= n { return Double(n - 1) }
        return Double(lo) + (t - clockTable[lo]) / (clockTable[lo + 1] - clockTable[lo])
    }

    private func seconds(at day: Double) -> Double {
        let d = max(0, min(Double(n) - 0.001, day)), i = Int(d)
        return clockTable[i] + (d - Double(i)) * (clockTable[i + 1] - clockTable[i])
    }

    private func activity(_ p: Int, _ w: Double) -> Double {
        if w <= 0 { return Double(level[p][0]) }
        if w >= Double(n - 1) { return Double(level[p][n - 1]) }
        let i = Int(w), u = w - Double(i)
        return Double(level[p][i]) * (1 - u) + Double(level[p][i + 1]) * u
    }

    private func side(_ p: Int) -> Double { lanes[p] % 2 == 1 ? 1 : -1 }
    private func near(_ p: Int) -> Double { 24 + Double(lanes[p] / 2) * 8 }
    private func y(_ p: Int, _ w: Double) -> Double {
        let a = activity(p, w)
        return cy + side(p) * (near(p) + (1 - a) * (far - near(p))) + sin(w / 7 * 0.35 + Double(p) * 1.7) * 5 * a
    }

    func advance(by step: Double) {
        let dt = min(0.05, max(0, step))
        wall += dt
        if filming {
            // Being filmed: run forward once and stop on today, without looping round.
            play = min(clockTable[n] - 0.0001, play + dt)
        } else if !held { play += dt }
    }

    // A shared video tells the whole story at the normal pace, from the first message to today, with a
    // moment on today at the end. The owner can ask for less, and choose which end to keep.
    private var filming = false
    var storySeconds: Double { (clockTable[n] + 2.5).rounded(.up) }
    func beginStory(length: Double, keepingEnd: Bool) {
        filming = true
        play = keepingEnd ? max(0, clockTable[n] - max(0, length - 2.5)) : 0
    }

    /// Moves playback so that it ends `secondsBeforeEnd` before the present day.
    func jump(secondsBeforeEnd: Double) { play = max(0, clockTable[n] - secondsBeforeEnd) }

    func pointerDown(_ p: CGPoint) { held = true; lastPointerX = p.x }
    func pointerMoved(_ p: CGPoint) {
        guard held else { return }
        let now = day(at: play) - (p.x - lastPointerX) / pxPerDay
        play = seconds(at: now)
        lastPointerX = p.x
    }
    func pointerUp(_ p: CGPoint) { held = false }

    func paint(_ p: Painter, _ options: DrawOptions) {
        let w = day(at: play)
        func x(_ d: Double) -> Double { cx + (d - w) * pxPerDay }
        for s in stars {
            let sx = ((s.0 - w / 7 * 46 * 0.35 * s.2).truncatingRemainder(dividingBy: 700) + 700).truncatingRemainder(dividingBy: 700) - 50
            p.rect(sx, s.1, 1.2, 1.2, Pal.paper.c(0.10 + 0.18 * s.2))
        }
        // My path: travelled behind me, faint and dotted ahead.
        p.line(0, cy, cx, cy, width: 1.5, RGB(255, 244, 220).c(0), RGB(255, 244, 220).c(0.5), round: false)
        var dash = cx + 9
        while dash < width { p.line(dash, cy, dash + 2, cy, width: 1.5, Pal.paper.c(0.10), round: false); dash += 9 }

        // First work out where everyone's face belongs at this moment.
        var heads: [(Int, Double, Double, Double, Double, RGB)] = []
        var trailEnd = [Double](repeating: 0, count: faces.count)
        for person in faces.indices.reversed() {
            let colour = Pal.series[person % Pal.series.count]
            let rest = Double(last[person]) + 3
            let fade = memory[person] ? max(0, min(1, (w - rest) / 21)) : 0
            let ease = fade * fade * (3 - 2 * fade)
            trailEnd[person] = memory[person] ? min(w, rest) : w
            let a = activity(person, w), visible = min(1, a / 0.05)
            if visible <= 0.01 && !(memory[person] && fade > 0) { continue }
            var px = cx, py = y(person, w), r = (2 + a * 4.5) * (0.4 + 0.6 * visible), alpha = (0.25 + 0.75 * a) * visible, c = colour
            if memory[person] && fade > 0 {           // stays as a steady light instead of drifting off
                let y0 = y(person, rest), a0 = activity(person, rest)
                px = cx + ease * 56; py = y0 + (104 - y0) * ease
                r = (2 + a0 * 4.5) * (1 - ease) + 3 * ease
                alpha = (0.25 + 0.75 * a0) * (1 - ease) + (0.8 + sin(wall * 1.3) * 0.08) * ease
                if ease > 0.5 { c = Pal.memory }
            }
            heads.append((person, px, py, r, alpha, c))
        }
        // Faces that would land on top of each other are eased apart, away from my line, so every name can
        // be read. How far each is moved is remembered and changed gradually, and the same shift is applied
        // to the end of that person's line below, so a face never comes away from its line.
        var wanted = [Double](repeating: 0, count: faces.count)
        for above in [true, false] {
            var column = heads.indices.filter { (heads[$0].2 < cy) == above && heads[$0].1 == cx }
            column.sort { abs(heads[$0].2 - cy) < abs(heads[$1].2 - cy) }
            var placed = column.map { heads[$0].2 }
            var previous: Double?
            for (k, i) in column.enumerated() {
                let size = 9 + heads[i].3 * 1.5
                if let last = previous, abs(placed[k] - cy) < last + size + 11 { placed[k] = cy + (above ? -1 : 1) * (last + size + 11) }
                previous = abs(placed[k] - cy) + size - 9
            }
            // If the stack would run off the picture, close it up evenly so everyone stays in view.
            let limit = (above ? cy : height - cy) - 26
            if let furthest = placed.map({ abs($0 - cy) }).max(), furthest > limit {
                placed = placed.map { cy + ($0 - cy) * limit / furthest }
            }
            for (k, i) in column.enumerated() { wanted[heads[i].0] = placed[k] - heads[i].2 }
        }
        if shift.count != faces.count { shift = wanted }
        for i in shift.indices { shift[i] += (wanted[i] - shift[i]) * 0.18 }
        for i in heads.indices where heads[i].1 == cx { heads[i].2 += shift[heads[i].0] }

        // Then the lines: where each person has been alongside me, bending to meet their face.
        p.additive = true
        let step = trail / 150, reach = 42.0
        for person in faces.indices.reversed() {
            let colour = Pal.series[person % Pal.series.count], end = trailEnd[person], moved = shift[person]
            func lifted(_ k: Double) -> Double {
                guard moved != 0, !memory[person] || end == w else { return y(person, k) }
                let near = max(0, 1 - (w - k) / reach)
                return y(person, k) + moved * near * near * (3 - 2 * near)
            }
            var k = max(0, w - trail)
            while k < end {
                let a = activity(person, k), f = 1 - (w - k) / trail
                if a > 0.004 {
                    let k2 = min(end, k + step * 1.5)
                    p.line(x(k), lifted(k), x(k2), lifted(k2), width: 0.8 + a * 4.2, colour.c(f * f * (0.08 + 0.75 * a)))
                }
                k += step
            }
        }
        for h in heads { p.glow(h.1, h.2, h.3 * 4.5, h.5, 0.45 * h.4) }
        p.radial(cx, cy, from: 0, to: 30, stops: [(0, RGB(255, 250, 235).c(1)), (0.2, RGB(255, 220, 160).c(0.5)), (1, Pal.amber.c(0))])
        p.additive = false
        for h in heads.sorted(by: { $0.4 < $1.4 }) { head(p, faces[h.0], h.1, h.2, h.3, h.4, h.5, options) }
        p.disc(cx, cy, 5, RGB(255, 250, 240).c())

        let date = firstDay.addingTimeInterval(max(0, min(Double(n - 1), w)) * 86400 + 43200)
        p.text(date.formatted(.dateTime.month(.wide).year()), 40, 52, .serif(26), Pal.paper.c(), anchor: .bottomLeading)
    }

    /// A face and a name beside it.
    private func head(_ p: Painter, _ face: Face, _ x: Double, _ y: Double, _ r: Double, _ alpha: Double, _ colour: RGB, _ options: DrawOptions) {
        let radius = 9 + r * 1.5
        p.save()
        p.opacity *= min(1, alpha < 0.05 ? alpha * 8 : 0.4 + alpha)
        p.disc(x, y, radius, RGB(21, 21, 28).c())
        p.portrait(face, x: x, y: y, r: radius, colour: colour, options: options, initialsFace: .sans)
        p.ring(x, y, radius, width: 1.5, colour.c())
        if !(options.names == .initials && (!options.photos || face.photo == nil)), let text = face.label(options.names) {
            p.text(text, x + radius + 7, y + 0.5, .sans(12), Pal.paper.c(), anchor: .leading)
        }
        p.restore()
    }
}
