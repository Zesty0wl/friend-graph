import SwiftUI

/// My circle: me in the middle, a strand out to each person, three rings. Nearer and warmer means
/// closer. Drag empty space to spin it, drag a person to move them between rings.
final class CircleScene: VisualScene {
    let designSize = CGSize(width: 720, height: 720)
    private let cx = 360.0, cy = 360.0
    static let zones: [(r: Double, label: String)] = [(166, "Inner circle"), (250, "Friends"), (326, "People I know")]
    private let seats: [(Double, Double)] = [(102, 106), (204, 212), (286, 292)]
    static let capacity = [5, 6, 7]

    private struct Body {
        var face: Face
        var person: Person
        var rank: Int
        var home: Double
        var x: Double, y: Double
        var vx = 0.0, vy = 0.0
        var radius = 3.0
        var emphasis = 0.0
        var phase: Double
        var born: Double
        var grow = 0.0
        var pop = 0.0
        var curl: Double
        var spin = 0.0
        var lastAngle: Double
        var colour = Pal.amber
        var curve: (CGPoint, CGPoint, CGPoint)?
        var startZone = 0
        var memory: Bool { face.standing == .inMemory }
    }
    private struct Spark { var body: Int; var u: Double; var direction: Double; var speed: Double }

    private var bodies: [Body] = []
    private var sparks: [Spark] = []
    private var random = Seeded(21)
    private var chance = Seeded(977)
    private var time = 0.0
    private var mePop = 0.0
    private var grabbed: Int?
    private var hovered: Int?
    private var pointer = CGPoint(x: 360, y: 360)
    private var spinRate = 0.03
    private var spinning = false
    private var lastSpinAngle = 0.0
    private var lastSpinTime = 0.0
    private let scoredCount: Int
    private let othersKnown: Int
    private let maxMessages: Double
    private let totalWeight: Double
    private let onRing: (String, Int) -> Void

    /// `firstBirth` and `stagger` set when each person appears; the film slows them down so each arrival can land on a note.
    init(people: [Person], decisions: Decisions, scoredCount: Int, othersKnown: Int, firstBirth: Double = 0.2, stagger: Double = 0.06,
         onRing: @escaping (String, Int) -> Void = { _, _ in }) {
        self.scoredCount = scoredCount
        self.othersKnown = othersKnown
        self.onRing = onRing
        let shown = Array(people.prefix(18))
        // Seat by closeness, unless the owner has dragged someone to a ring of their choosing.
        var tiers: [Int] = []
        for (k, p) in shown.enumerated() { tiers.append(decisions.ring[p.id] ?? (k < 5 ? 0 : k < 11 ? 1 : 2)) }
        var counts = [0, 0, 0]
        for t in tiers { counts[t] += 1 }
        var seen = [0, 0, 0]
        for (k, p) in shown.enumerated() {
            let tier = tiers[k], inTier = seen[tier], n = max(Self.capacity[tier], counts[tier])
            seen[tier] += 1
            let home = seats[tier].0 + (seats[tier].1 - seats[tier].0) * Double(inTier % 2)
            let a = Double(inTier) / Double(n) * TAU + Double(tier) * 0.5 + 0.55
            let phase = random.next() * TAU, curl = (random.next() - 0.5) * 0.22
            bodies.append(Body(face: Face(p, decisions), person: p, rank: k, home: home, x: cx + cos(a) * 24, y: cy + sin(a) * 24,
                               phase: phase, born: firstBirth + Double(k) * stagger, curl: curl, lastAngle: a))
        }
        maxMessages = Double(max(1, bodies.map { $0.person.messages }.max() ?? 1))
        totalWeight = bodies.filter { !$0.memory }.reduce(0) { $0 + sqrt(Double($1.person.messages)) }
    }

    private func zone(of d: Double) -> Int { d < Self.zones[0].r ? 0 : d < Self.zones[1].r ? 1 : 2 }
    private func size(at d: Double) -> Double {
        let u = max(0, min(1, (d - 104) / 190))
        return 19 + 23 * pow(1 - u, 1.3)
    }
    private func distance(_ b: Body) -> Double { hypot(b.x - cx, b.y - cy) }
    private var pinned: Int?
    private var selected: Int? { grabbed ?? hovered ?? pinned }

    private func body(at p: CGPoint) -> Int? {
        var best: Int?
        for (i, b) in bodies.enumerated() where b.grow > 0.02 && hypot(b.x - p.x, b.y - p.y) < b.radius + 4 {
            if best == nil || b.radius < bodies[best!].radius { best = i }
        }
        return best
    }

    /// Each ring turns at its own pace: the inner circle quickest, the outer ring slowest.
    private let ringPace = [1.4, 1.0, 0.65]
    private let drift = 0.03

    private func rotateAll(_ angle: Double, perRing: Bool = false) {
        for i in bodies.indices where i != grabbed {
            let turn = perRing ? angle * ringPace[zone(of: bodies[i].home)] : angle
            let co = cos(turn), si = sin(turn)
            let x = bodies[i].x - cx, y = bodies[i].y - cy, vx = bodies[i].vx, vy = bodies[i].vy
            bodies[i].x = cx + x * co - y * si; bodies[i].y = cy + x * si + y * co
            bodies[i].vx = vx * co - vy * si; bodies[i].vy = vx * si + vy * co
        }
    }

    // MARK: Pointer

    func pointerDown(_ p: CGPoint) {
        pointer = p
        grabbed = body(at: p)
        if let g = grabbed { bodies[g].startZone = zone(of: bodies[g].home) } else {
            spinning = true
            lastSpinAngle = atan2(p.y - cy, p.x - cx)
            lastSpinTime = time
        }
    }

    func pointerMoved(_ p: CGPoint) {
        pointer = p
        if spinning {
            let angle = atan2(p.y - cy, p.x - cx), delta = wrapAngle(angle - lastSpinAngle)
            let dt = max(0.008, time - lastSpinTime)
            rotateAll(delta)
            spinRate = spinRate * 0.6 + (delta / dt) * 0.4
            lastSpinAngle = angle; lastSpinTime = time
        }
    }

    func pointerUp(_ p: CGPoint) {
        spinning = false
        guard let g = grabbed else { return }
        let d = distance(bodies[g]), z = zone(of: d)
        bodies[g].home = max(seats[z].0, min(seats[z].1, d))
        if z != bodies[g].startZone { onRing(bodies[g].person.id, z) }
        grabbed = nil
        hovered = body(at: p)
    }

    func hover(_ p: CGPoint?) {
        guard grabbed == nil, !spinning else { return }
        if let p { pointer = p; hovered = body(at: p) } else { hovered = nil }
    }

    /// How fast each ring is actually turning, in radians a second. For checking.
    var ringSpeeds: [Double] {
        (0..<3).map { ring in
            let members = bodies.filter { zone(of: $0.home) == ring }
            return members.isEmpty ? 0 : members.reduce(0) { $0 + $1.spin } / Double(members.count)
        }
    }

    /// Selects someone without a pointer, for saved pictures and tests.
    func select(index: Int?) { pinned = index.flatMap { $0 < bodies.count ? $0 : nil } }

    // MARK: Words

    var detailKey: String {
        guard let s = selected else { return "none" }
        return bodies[s].person.id + ":\(zone(of: bodies[s].home))"
    }

    var selectedPersonID: String? { selected.map { bodies[$0].person.id } }

    var detail: Detail? {
        guard let s = selected else { return nil }
        let b = bodies[s], p = b.person
        let ring = Self.zones[zone(of: grabbed == s ? distance(b) : b.home)].label
        var subtitle = [ring, b.face.relationship.label]
        if b.memory { subtitle.append("In memory") }
        var rows: [Detail.Row] = []
        if b.memory {
            rows.append(.init(label: "Messages", value: "\(p.messages.formatted()) between us in the past year"))
            if p.calls > 0 { rows.append(.init(label: "Calls", value: "\(p.calls), \(Int(p.callMinutes.rounded())) minutes in all")) }
        } else {
            subtitle.append("number \(b.rank + 1) of the \(scoredCount) people I really talk to")
            rows.append(.init(label: "Messages", value: "\(p.messages.formatted()) this year (\(p.outgoing.formatted()) from me, \(p.incoming.formatted()) from them)"))
            rows.append(.init(label: "I reply in", value: minutesText(p.myReplyMinutes)))
            rows.append(.init(label: "They reply in", value: minutesText(p.theirReplyMinutes)))
            if p.calls > 0 { rows.append(.init(label: "Calls", value: "\(p.calls), \(Int(p.callMinutes.rounded())) minutes in all")) }
        }
        return Detail(title: p.name, subtitle: subtitle.joined(separator: " · "), rows: rows)
    }

    var footer: String {
        var counts = [0, 0, 0]
        for (i, b) in bodies.enumerated() { counts[zone(of: i == grabbed ? distance(b) : b.home)] += 1 }
        return "\(counts[0]) inner circle · \(counts[1]) friends · \(counts[2]) people I know · \(othersKnown.formatted()) more my Mac knows of"
    }

    // MARK: Motion

    func advance(by step: Double) {
        let dt = min(0.04, max(0.001, step))
        time += dt
        let t = time
        if !spinning {
            rotateAll(spinRate * dt, perRing: true)
            spinRate += (drift - spinRate) * min(1, dt * 1.4)
        }
        for i in bodies.indices where t >= bodies[i].born {
            var b = bodies[i]
            b.grow += (1 - b.grow) * min(1, dt * 4)
            b.pop *= 0.9
            if i == grabbed {
                b.vx = (pointer.x - b.x) * 22; b.vy = (pointer.y - b.y) * 22
            } else {
                let dx = b.x - cx, dy = b.y - cy, d = max(0.01, hypot(dx, dy)), pull = (b.home - d) * 26
                b.vx += (dx / d * pull + cos(t * 0.5 + b.phase) * 3) * dt
                b.vy += (dy / d * pull + sin(t * 0.6 + b.phase) * 3) * dt
                let damp = 1 - min(1, dt * 3.2)
                b.vx *= damp; b.vy *= damp
            }
            b.x += b.vx * dt; b.y += b.vy * dt
            let d = hypot(b.x - cx, b.y - cy)
            b.radius += (size(at: d) * (0.2 + 0.8 * b.grow) - b.radius) * min(1, dt * 9)
            b.emphasis += ((i == selected ? 1 : 0) - b.emphasis) * min(1, dt * 11)
            b.colour = b.memory ? Pal.memory : Pal.warmth(d)
            bodies[i] = b
        }
        // Spread each ring's people evenly round it: everyone eases toward the midpoint of their two neighbours.
        for ring in 0..<3 {
            let members = bodies.indices.filter { $0 != grabbed && bodies[$0].grow > 0.3 && zone(of: bodies[$0].home) == ring }
                .sorted { atan2(bodies[$0].y - cy, bodies[$0].x - cx) < atan2(bodies[$1].y - cy, bodies[$1].x - cx) }
            guard members.count > 1 else { continue }
            let angles = members.map { atan2(bodies[$0].y - cy, bodies[$0].x - cx) }
            for (k, i) in members.enumerated() {
                let before = angles[(k + members.count - 1) % members.count], after = angles[(k + 1) % members.count]
                var gapBefore = angles[k] - before, gapAfter = after - angles[k]
                if gapBefore <= 0 { gapBefore += TAU }
                if gapAfter <= 0 { gapAfter += TAU }
                let d = max(1, distance(bodies[i])), push = (gapAfter - gapBefore) * 0.9 * d * dt
                bodies[i].vx += -(bodies[i].y - cy) / d * push
                bodies[i].vy += (bodies[i].x - cx) / d * push
            }
        }
        // Keep people off me, off each other, off the ring labels and inside the picture.
        for _ in 0..<4 {
            for i in bodies.indices where bodies[i].grow > 0 {
                let dc = max(0.01, hypot(bodies[i].x - cx, bodies[i].y - cy)), minimum = (bodies[i].radius + 48) * bodies[i].grow
                if dc < minimum {
                    bodies[i].x += (bodies[i].x - cx) / dc * (minimum - dc)
                    bodies[i].y += (bodies[i].y - cy) / dc * (minimum - dc)
                }
                for j in bodies.indices where j > i && bodies[j].grow > 0 {
                    let dx = bodies[j].x - bodies[i].x, dy = bodies[j].y - bodies[i].y
                    let dist = max(0.01, hypot(dx, dy)), gap = bodies[i].radius + bodies[j].radius + 18
                    guard dist < gap else { continue }
                    let o = (gap - dist) / 2, ux = dx / dist, uy = dy / dist
                    let wi = i == grabbed ? 0.0 : j == grabbed ? 2.0 : 1.0, wj = 2 - wi
                    bodies[i].x -= ux * o * wi; bodies[i].y -= uy * o * wi
                    bodies[j].x += ux * o * wj; bodies[j].y += uy * o * wj
                    bodies[i].vx -= ux * o * 5 * wi; bodies[i].vy -= uy * o * 5 * wi
                    bodies[j].vx += ux * o * 5 * wj; bodies[j].vy += uy * o * 5 * wj
                }
                let r = bodies[i].radius
                bodies[i].x = max(r + 8, min(720 - r - 8, bodies[i].x))
                bodies[i].y = max(r + 8, min(720 - r - 24, bodies[i].y))
            }
        }
        // How fast each person is swinging round me, so their strand can lag behind.
        for i in bodies.indices {
            let angle = atan2(bodies[i].y - cy, bodies[i].x - cx)
            bodies[i].spin += (wrapAngle(angle - bodies[i].lastAngle) / dt - bodies[i].spin) * min(1, dt * 7)
            bodies[i].lastAngle = angle
        }
        // The strand each person's messages travel along.
        for i in bodies.indices {
            let b = bodies[i]
            guard b.grow >= 0.02 else { bodies[i].curve = nil; continue }
            let d = max(1, distance(b)), angle = atan2(b.y - cy, b.x - cx), r1 = 27.0, r2 = max(r1 + 2, d - b.radius - 4)
            let bend = b.curl - max(-0.7, min(0.7, b.spin * 0.16)), rm = (r1 + r2) / 2
            bodies[i].curve = (pt(cx + cos(angle) * r1, cy + sin(angle) * r1),
                               pt(cx + cos(angle + bend) * rm, cy + sin(angle + bend) * rm),
                               pt(cx + cos(angle) * r2, cy + sin(angle) * r2))
        }
        // Messages: each travels at the pace we really reply. Nobody in memory sends or receives.
        mePop *= 0.9
        let focus = selected.flatMap { bodies[$0].memory ? nil : $0 }
        let rate = focus != nil ? 5.0 : 2.2
        if t > 1.8, totalWeight > 0, chance.next() < rate * dt {
            var pick = focus
            if pick == nil {
                var r = chance.next() * totalWeight
                for (i, b) in bodies.enumerated() where !b.memory {
                    pick = pick ?? i
                    r -= sqrt(Double(b.person.messages))
                    if r <= 0 { pick = i; break }
                }
            }
            if let i = pick {
                let p = bodies[i].person
                let out = chance.next() < Double(p.outgoing) / Double(max(1, p.incoming + p.outgoing))
                sparks.append(Spark(body: i, u: out ? 0 : 1, direction: out ? 1 : -1, speed: 0.3 + 0.55 * pace(out ? p.myReplyMinutes : p.theirReplyMinutes)))
            }
        }
        var travelling: [Spark] = []
        for var s in sparks {
            s.u += s.direction * s.speed * dt
            if s.u < 0 || s.u > 1 {
                if s.direction > 0 { bodies[s.body].pop = 1 } else { mePop = 1 }
            } else { travelling.append(s) }
        }
        sparks = travelling
    }

    private func pace(_ minutes: Double?) -> Double {
        guard let m = minutes else { return 0.25 }
        return max(0.12, min(1.6, 1.2 / (1 + log10(1 + m * 4))))
    }

    // MARK: Drawing

    func paint(_ p: Painter, _ options: DrawOptions) {
        let sel = selected
        p.radial(cx, cy, from: 20, to: 340, stops: [(0, Pal.amber.c(0.17)), (0.4, Pal.rose.c(0.055)), (0.75, Pal.violet.c(0.03)), (1, Pal.ground.c(0))])

        // Three faint rings, each in the colour of its distance and broken at the top for its label.
        let target = grabbed.map { zone(of: distance(bodies[$0])) }
        let labelStyle = TextStyle.sans(10.5, .medium, tracking: 1.2)
        for (i, z) in Self.zones.enumerated() {
            let on = i == target, c = Pal.warmth((seats[i].0 + seats[i].1) / 2)
            let text = z.label.uppercased(), half = (p.measure(text, labelStyle).width / 2 + 10) / z.r
            p.ring(cx, cy, z.r, width: 1, c.c(on ? 0.7 : 0.2), from: -Double.pi / 2 + half, sweep: TAU - 2 * half)
            p.text(text, cx, cy - z.r, labelStyle, c.c(on ? 1 : 0.8))
        }

        p.additive = true
        for (i, b) in bodies.enumerated() {
            guard let c = b.curve else { continue }
            let alpha = (0.5 * (sel != nil && sel != i ? 0.3 : 1) + b.emphasis * 0.4) * min(1, b.grow * 1.5) * (b.memory ? 0.55 : 1)
            let width = 1.1 + 3.4 * sqrt(Double(b.person.messages) / maxMessages) + b.emphasis * 1.2
            let warm = RGB(255, 220, 170).c(alpha * 0.85), near = b.colour.c(alpha), far = b.colour.c(alpha * 0.6)
            p.curve(c.0, c.1, c.2, width: width, warm, near, far, at: 0.35)
        }
        let focus = sel.flatMap { bodies[$0].memory ? nil : $0 }
        for s in sparks {
            guard let c = bodies[s.body].curve else { continue }
            let colour = s.direction > 0 ? RGB(255, 240, 215) : bodies[s.body].colour
            let alpha = (sin(s.u * .pi) * 0.75 + 0.25) * (focus != nil && focus != s.body ? 0.25 : 1)
            for k in 0..<7 {
                let u = s.u - s.direction * Double(k) * 0.025
                guard u >= 0, u <= 1 else { continue }
                let w = 1 - u
                let x = w * w * c.0.x + 2 * w * u * c.1.x + u * u * c.2.x, y = w * w * c.0.y + 2 * w * u * c.1.y + u * u * c.2.y
                p.glow(x, y, 6 - Double(k) * 0.65, colour, alpha * (1 - Double(k) * 0.14))
            }
        }

        // Me: the warm light everything grows from.
        let pr = 24 + sin(time * 0.55) + mePop * 1.8
        p.radial(cx, cy, from: pr - 4, to: pr + 30, RGB(255, 190, 110).c(0.5), Pal.amber.c(0))
        p.additive = false
        p.disc(cx, cy, pr, Pal.core.c())
        p.text("Me", cx, cy + 0.5, .serif(21), RGB(26, 18, 8).c())

        let order = bodies.indices.sorted { a, b in
            if (a == sel) != (b == sel) { return b == sel }
            return bodies[a].radius < bodies[b].radius
        }
        for i in order where bodies[i].grow > 0.02 {
            face(p, bodies[i], alpha: (sel != nil && sel != i ? 0.4 : 1) * min(1, bodies[i].grow * 2), options)
        }
        guard options.names != .none else { return }
        for i in order {
            let b = bodies[i], r = b.radius * (1 + b.emphasis * 0.06), nameY = b.y + r + 15
            // With photos hidden and initials chosen, the disc already carries the initials.
            if options.names == .initials && (!options.photos || b.face.photo == nil) { continue }
            var visible = (r > 24 || options.everyoneNamed ? 1 : b.emphasis) * min(1, b.grow * 2) * (sel != nil && sel != i ? 0.4 : 1)
            for z in Self.zones where abs(nameY - (cy - z.r)) < 15 && abs(b.x - cx) < Double(z.label.count) * 4.4 + 30 {
                visible *= b.emphasis            // never write a name across a ring's label
            }
            // Under a face there is only room for a first name.
            guard visible > 0.03, let text = options.everyoneNamed ? b.face.first : b.face.label(options.names) else { continue }
            p.save()
            p.opacity *= visible
            p.text(text, b.x, b.y + r + 9, .sans(r > 24 ? 12.5 : 11), Pal.paper.c(), anchor: .top, halo: Pal.ground.c())
            p.restore()
        }
    }

    /// A flat portrait with one thin ring in its own colour. No gloss, no shadow.
    private func face(_ p: Painter, _ b: Body, alpha: Double, _ options: DrawOptions) {
        let r = b.radius * (1 + b.emphasis * 0.06 + b.pop * 0.06)
        p.save()
        p.opacity *= alpha            // multiplied, so a picture inside a fading film chapter fades with it
        if b.memory {
            p.additive = true
            p.glow(b.x, b.y, r + 16, Pal.memory, 0.22 + 0.04 * sin(time * 1.3))
            p.additive = false
        }
        p.disc(b.x, b.y, r + 4, Pal.ground.c())
        p.portrait(b.face, x: b.x, y: b.y, r: r, colour: b.colour, options: options)
        p.ring(b.x, b.y, r + 3.5, width: 1.5 + b.emphasis * 1.2 + b.pop * 1.5, b.colour.c(0.75 + 0.25 * b.emphasis))
        p.restore()
    }
}
