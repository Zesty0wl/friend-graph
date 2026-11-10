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
        if !held { play += dt }
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

    func draw(_ g: inout GraphicsContext, _ options: DrawOptions) {
        let w = day(at: play)
        func x(_ d: Double) -> Double { cx + (d - w) * pxPerDay }
        g.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(Pal.ground.color()))
        for s in stars {
            let sx = ((s.0 - w / 7 * 46 * 0.35 * s.2).truncatingRemainder(dividingBy: 700) + 700).truncatingRemainder(dividingBy: 700) - 50
            g.fill(Path(CGRect(x: sx, y: s.1, width: 1.2, height: 1.2)), with: .color(Pal.paper.color(0.10 + 0.18 * s.2)))
        }
        // My path: travelled behind me, faint ahead.
        var behind = Path(); behind.move(to: pt(0, cy)); behind.addLine(to: pt(cx, cy))
        g.stroke(behind, with: .linearGradient(Gradient(colors: [RGB(255, 244, 220).color(0), RGB(255, 244, 220).color(0.5)]),
                                               startPoint: pt(0, cy), endPoint: pt(cx, cy)), lineWidth: 1.5)
        var ahead = Path(); ahead.move(to: pt(cx, cy)); ahead.addLine(to: pt(width, cy))
        g.stroke(ahead, with: .color(Pal.paper.color(0.10)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 7]))

        var light = g
        light.blendMode = .plusLighter
        let step = trail / 150
        var heads: [(Int, Double, Double, Double, Double, RGB)] = []
        for p in faces.indices.reversed() {
            let colour = Pal.series[p % Pal.series.count]
            let rest = Double(last[p]) + 3
            let fade = memory[p] ? max(0, min(1, (w - rest) / 21)) : 0
            let ease = fade * fade * (3 - 2 * fade)
            // The trail: where they have been alongside me.
            let end = memory[p] ? min(w, rest) : w
            var k = max(0, w - trail)
            while k < end {
                let a = activity(p, k), f = 1 - (w - k) / trail
                if a > 0.004 {
                    let k2 = min(end, k + step * 1.5)
                    var seg = Path(); seg.move(to: pt(x(k), y(p, k))); seg.addLine(to: pt(x(k2), y(p, k2)))
                    light.stroke(seg, with: .color(colour.color(f * f * (0.08 + 0.75 * a))), style: StrokeStyle(lineWidth: 0.8 + a * 4.2, lineCap: .round))
                }
                k += step
            }
            let a = activity(p, w), visible = min(1, a / 0.05)
            if visible <= 0.01 && !(memory[p] && fade > 0) { continue }
            var px = cx, py = y(p, w), r = (2 + a * 4.5) * (0.4 + 0.6 * visible), alpha = (0.25 + 0.75 * a) * visible, c = colour
            if memory[p] && fade > 0 {           // stays as a steady light instead of drifting off
                let y0 = y(p, rest), a0 = activity(p, rest)
                px = cx + ease * 56; py = y0 + (104 - y0) * ease
                r = (2 + a0 * 4.5) * (1 - ease) + 3 * ease
                alpha = (0.25 + 0.75 * a0) * (1 - ease) + (0.8 + sin(wall * 1.3) * 0.08) * ease
                if ease > 0.5 { c = Pal.memory }
            }
            light.glow(px, py, r * 4.5, c, 0.45 * alpha)
            heads.append((p, px, py, r, alpha, c))
        }
        // Faces that land on top of each other are eased apart, away from my line, so every name can be read.
        for above in [true, false] {
            var column = heads.indices.filter { (heads[$0].2 < cy) == above && heads[$0].1 == cx }
            column.sort { abs(heads[$0].2 - cy) < abs(heads[$1].2 - cy) }
            var previous: Double?
            for i in column {
                let size = 9 + heads[i].3 * 1.5
                if let last = previous, abs(heads[i].2 - cy) < last + size + 11 {
                    heads[i].2 = cy + (above ? -1 : 1) * (last + size + 11)
                }
                previous = abs(heads[i].2 - cy) + size - 9
            }
        }
        for h in heads.sorted(by: { $0.4 < $1.4 }) { head(&g, faces[h.0], h.1, h.2, h.3, h.4, h.5, options) }
        light.fill(circle(cx, cy, 30), with: .radialGradient(Gradient(stops: [
            .init(color: RGB(255, 250, 235).color(1), location: 0), .init(color: RGB(255, 220, 160).color(0.5), location: 0.2),
            .init(color: Pal.amber.color(0), location: 1),
        ]), center: pt(cx, cy), startRadius: 0, endRadius: 30))
        g.fill(circle(cx, cy, 5), with: .color(RGB(255, 250, 240).color()))

        let date = firstDay.addingTimeInterval(max(0, min(Double(n - 1), w)) * 86400 + 43200)
        g.label(date.formatted(.dateTime.month(.wide).year()), at: pt(40, 52), font: serif(26), color: Pal.paper.color(), anchor: .bottomLeading)
    }

    /// A face (or initials) and a name beside it.
    private func head(_ g: inout GraphicsContext, _ face: Face, _ x: Double, _ y: Double, _ r: Double, _ alpha: Double, _ colour: RGB, _ options: DrawOptions) {
        let radius = 9 + r * 1.5
        var layer = g
        layer.opacity = min(1, alpha < 0.05 ? alpha * 8 : 0.4 + alpha)
        layer.fill(circle(x, y, radius), with: .color(RGB(21, 21, 28).color()))
        if options.photos, let image = face.image {
            var clipped = layer
            clipped.clip(to: circle(x, y, radius))
            clipped.draw(image, in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        } else if options.names != .none {
            layer.label(face.initials, at: pt(x, y + 0.5), font: sans(radius * 0.8, .medium), color: colour.color())
        }
        layer.stroke(circle(x, y, radius), with: .color(colour.color()), lineWidth: 1.5)
        if options.names == .initials && (!options.photos || face.image == nil) { return }
        if let text = face.label(options.names) {
            layer.label(text, at: pt(x + radius + 7, y + 0.5), font: sans(12), color: Pal.paper.color(), anchor: .leading)
        }
    }
}
