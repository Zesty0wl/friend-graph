import SwiftUI

/// What my Mac is working out about me: every strand is one thing macOS keeps up to date.
/// Longer strands draw on more sources, brighter ones ran more recently.
final class IrisScene: VisualScene {
    let designSize = CGSize(width: 820, height: 820)
    private let cx = 410.0, cy = 410.0, pupil = 50.0, reach = 196.0
    /// Strand names stop here, so the group labels beyond them stay clear.
    private let nameLimit = 352.0

    private struct Strand {
        var view: WatchView
        var angle: Double
        var heat: Double
        var length: Double
        var offset = 0.0, velocity = 0.0, emphasis = 0.0
        var curl: Double, phase: Double
    }
    private var strands: [Strand] = []
    private let data: WatchData
    private var middles: [Int: [Double]] = [:]
    private var rotation = 0.0, rate = 0.02
    private var hovered: Int?, pinned: Int?
    private var dragging = false, lastAngle = 0.0, lastTime = 0.0, moved = 0.0
    private var time = 0.0
    private let mostRows: Double

    init(_ data: WatchData) {
        self.data = data
        mostRows = max(1, log10(1 + Double(data.views.compactMap(\.rows).max() ?? 0)))
        var random = Seeded(29)
        let gap = 0.07, groups = Set(data.views.map(\.cat)).count
        let step = (TAU - gap * Double(groups)) / Double(max(1, data.views.count))
        var angle = -Double.pi / 2
        var previous: Int?
        for v in data.views {
            if let p = previous, p != v.cat { angle += gap }
            previous = v.cat
            let age = Double(data.captured - v.last)
            let heat = v.last == 0 ? 0.12 : age < 3600 ? 1 : age < 86400 ? 0.6 : 0.3
            let curl = (random.next() - 0.5) * 0.09, phase = random.next()
            strands.append(Strand(view: v, angle: angle, heat: heat, length: min(1, 0.5 + 0.5 * sqrt(Double(v.listens.count) / 8)), curl: curl, phase: phase))
            middles[v.cat, default: []].append(angle)
            angle += step
        }
    }

    private var selected: Int? { hovered ?? pinned }

    private func pick(_ p: CGPoint) -> Int? {
        let x = p.x - cx, y = p.y - cy, r = hypot(x, y)
        guard r >= pupil - 4, r <= nameLimit + 6 else { return nil }
        let angle = atan2(y, x) - rotation
        var best: Int?, closest = 0.06
        for (i, s) in strands.enumerated() {
            let d = abs(wrapAngle(s.angle + s.offset - angle))
            if d < closest { closest = d; best = i }
        }
        return best
    }

    func pointerDown(_ p: CGPoint) {
        dragging = true; moved = 0
        lastAngle = atan2(p.y - cy, p.x - cx); lastTime = time
    }
    func pointerMoved(_ p: CGPoint) {
        guard dragging else { return }
        let angle = atan2(p.y - cy, p.x - cx), delta = wrapAngle(angle - lastAngle), dt = max(0.008, time - lastTime)
        rotation += delta
        rate = rate * 0.6 + (delta / dt) * 0.4
        moved += abs(delta)
        lastAngle = angle; lastTime = time
        for i in strands.indices { strands[i].velocity -= delta * 7 }      // strands lag behind the spin, then whip back
    }
    func pointerUp(_ p: CGPoint) {
        guard dragging else { return }
        dragging = false
        if moved < 0.03 {
            let hit = pick(p)
            pinned = hit == pinned ? nil : hit
            hovered = hit
        }
    }
    func hover(_ p: CGPoint?) {
        guard !dragging else { return }
        hovered = p.flatMap(pick)
    }
    func select(named name: String) { pinned = strands.firstIndex { $0.view.name == name } }

    var footer: String { "Plain descriptions are read from Apple's internal names. Apple documents none of this." }
    var detailKey: String { selected.map { strands[$0].view.name } ?? "none" }

    var detail: Detail? {
        guard let s = selected else { return nil }
        let v = strands[s].view
        func source(_ l: WatchView.Listener) -> String {
            switch l.type {
            case "biome": return l.ref + " (live activity stream)"
            case "view": return l.ref + " (another strand)"
            case "knowledgeGraph": return "my graph"
            case "globalKnowledgeGraph": return "Apple's built-in world knowledge"
            case "alwaysUpdate": return "a timer"
            default: return l.type
            }
        }
        func schedule(_ x: String) -> String {
            if let m = WatchReader.matches(#"^every(\d+)(Minutes|Hours)$"#, x) { return "every \(m[1]) \(m[2].lowercased())" }
            let known = ["live": "the moment its source changes", "none": "whenever what it depends on changes", "daily": "once a day", "weekly": "once a week"]
            return known[x] ?? (x.isEmpty ? "not stated" : x)
        }
        func unique(_ xs: [String]) -> [String] { var seen = Set<String>(); return xs.filter { seen.insert($0).inserted } }
        let sources = unique(v.listens.map(source))
        let fed = sources.isEmpty ? "no listener of its own; other strands read it"
            : sources.prefix(5).joined(separator: ", ") + (sources.count > 5 ? ", and \(sources.count - 5) more" : "")
        let updates = unique(v.listens.map { schedule($0.schedule) }).joined(separator: "; ")
        let age = data.captured - v.last
        let ran = v.last == 0 ? "no run recorded" : age < 120 ? "moments ago" : age < 7200 ? "\(age / 60) minutes ago"
            : age < 172_800 ? "\(age / 3600) hours ago" : "\(age / 86400) days ago"
        var rows = [Detail.Row(label: "Fed by", value: fed), Detail.Row(label: "Updates", value: updates.isEmpty ? "not stated" : updates),
                    Detail.Row(label: "Last ran", value: ran)]
        rows.insert(.init(label: "Holds", value: v.rows.map { $0 == 0 ? "nothing on this Mac" : $0 == 1 ? "1 record" : "\($0.formatted()) records" } ?? "something I can't count from here"), at: 0)
        if !v.target.isEmpty { rows.append(.init(label: "Published to", value: v.target)) }
        return Detail(title: v.what, subtitle: "\(data.cats[min(v.cat, data.cats.count - 1)]) · macOS calls it “\(v.name)”", rows: rows)
    }

    func advance(by step: Double) {
        let dt = min(0.05, max(0.001, step))
        time += dt
        if !dragging { rotation += rate * dt; rate += (0.02 - rate) * min(1, dt * 1.4) }
        let sel = selected
        for i in strands.indices {
            var push = 0.0
            if let s = sel, s != i {
                let d = wrapAngle(strands[i].angle - strands[s].angle)
                push = (d < 0 ? -1 : 1) * 0.055 * exp(-abs(d) / 0.13)
            }
            strands[i].velocity += ((push - strands[i].offset) * 70 - strands[i].velocity * 9) * dt
            strands[i].offset += strands[i].velocity * dt
            strands[i].emphasis += ((i == sel ? 1 : 0) - strands[i].emphasis) * min(1, dt * 12)
        }
    }

    func paint(_ p: Painter, _ options: DrawOptions) {
        let sel = selected
        let pr = pupil + sin(time * 0.55) * 3 + (sel != nil ? 5 : 0), r1 = pr + 8
        p.radial(cx, cy, from: pr, to: reach + 10, stops: [(0, Pal.amber.c(0.16)), (0.35, RGB(79, 214, 224).c(0.07)), (1, Pal.ground.c(0))])

        p.additive = true
        for (i, s) in strands.enumerated() {
            let angle = rotation + s.angle + s.offset, r2 = r1 + (reach - r1) * s.length + s.emphasis * 18
            let c = Pal.categories[min(s.view.cat, Pal.categories.count - 1)], bend = s.curl - s.velocity * 0.035
            let a = pt(cx + cos(angle) * r1, cy + sin(angle) * r1), b = pt(cx + cos(angle) * r2, cy + sin(angle) * r2)
            let rm = (r1 + r2) / 2, m = pt(cx + cos(angle + bend) * rm, cy + sin(angle + bend) * rm)
            let alpha = (0.22 + 0.6 * s.heat) * (sel != nil && sel != i ? 0.4 : 1) + s.emphasis * 0.6
            let warm = RGB(255, 220, 170).c(alpha * 0.8), near = c.c(alpha), far = c.c(alpha * 0.25)
            p.curve(a, m, b, width: 2.1 + s.emphasis * 2.2, warm, near, far, at: 0.3)
            if s.heat == 1 {                         // ran in the last hour: a spark runs along it
                let u = (time * 0.45 + s.phase).truncatingRemainder(dividingBy: 1), q = 1 - u
                let x = q * q * a.x + 2 * q * u * m.x + u * u * b.x, y = q * q * a.y + 2 * q * u * m.y + u * u * b.y
                p.disc(x, y, 1.8, RGB(255, 245, 225).c(0.9 * sin(u * .pi)))
            }
            // The tip shows how much the strand holds: a bigger dot for more records, a hollow one for none.
            let tip = min(1, alpha + 0.2)
            if let rows = s.view.rows, rows == 0 {
                p.ring(b.x, b.y, 2.6 + s.emphasis * 2, width: 1, c.c(tip * 0.9))
            } else {
                let size = s.view.rows.map { 1.6 + 4.2 * log10(1 + Double($0)) / mostRows } ?? 1.8
                p.disc(b.x, b.y, size + s.emphasis * 2.5, c.c(tip))
            }
        }
        p.additive = false

        // macOS's own name for each strand, written along it from the tip outwards.
        for (i, s) in strands.enumerated() {
            let angle = rotation + s.angle + s.offset, start = r1 + (reach - r1) * s.length + s.emphasis * 18 + 9
            let room = Int((nameLimit - start) / 4.15)
            guard room > 4 else { continue }
            let name = s.view.name.count > room ? String(s.view.name.prefix(room - 1)) + "…" : s.view.name
            let c = Pal.categories[min(s.view.cat, Pal.categories.count - 1)], flipped = cos(angle) < 0
            let alpha = sel == nil ? (s.view.rows == 0 ? 0.5 : 0.82) : (sel == i ? 1 : 0.28)
            p.text(name, cx + cos(angle) * start, cy + sin(angle) * start, .sans(7.6, sel == i ? .semibold : .regular),
                   RGB.mix(c, Pal.paper, sel == i ? 0.5 : 0.35).c(alpha), anchor: flipped ? .trailing : .leading, angle: flipped ? angle + .pi : angle)
        }

        p.disc(cx, cy, pr, RGB(2, 2, 4).c())
        p.radial(cx - 22, cy - 26, from: 0, to: 24, stops: [(0, RGBA(r: 1, g: 1, b: 1, a: 0.8)), (0.35, RGBA(r: 1, g: 1, b: 1, a: 0.16)), (1, RGBA(r: 1, g: 1, b: 1, a: 0))])

        let groupStyle = TextStyle.sans(12, .medium)
        for (cat, angles) in middles {
            guard let first = angles.first, let last = angles.last else { continue }
            let angle = rotation + (first + last) / 2, co = cos(angle)
            let on = sel.map { strands[$0].view.cat == cat } ?? false
            let anchor: Anchor = co > 0.35 ? .leading : co < -0.35 ? .trailing : .centre
            let text = "\(data.cats[min(cat, data.cats.count - 1)]) \(angles.count)", wide = p.measure(text, groupStyle).width
            var x = cx + co * (nameLimit + 14)
            if anchor == .leading { x = min(x, 812 - wide) } else if anchor == .trailing { x = max(x, 8 + wide) } else { x = max(8 + wide / 2, min(812 - wide / 2, x)) }
            p.text(text, x, max(14, min(806, cy + sin(angle) * (nameLimit + 22))), groupStyle,
                   Pal.categories[min(cat, Pal.categories.count - 1)].c(sel != nil && !on ? 0.45 : 1), anchor: anchor)
        }
    }
}
