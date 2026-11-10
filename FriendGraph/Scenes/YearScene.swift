import SwiftUI

/// A year with my circle: one ribbon per person, closest at the top, swelling in the weeks we
/// talked most and thinning out when we went quiet.
final class YearScene: VisualScene {
    let designSize = CGSize(width: 600, height: 540)
    private let faces: [Face]
    private let people: [Person]
    private var weekly: [[Double]] = []
    private let weeks = 53
    private let x0 = 96.0, x1 = 572.0, top = 46.0, row = 45.0
    private var months: [(Int, String)] = []
    private var time = 0.0
    private var hovered: Int?

    init(people: [Person], decisions: Decisions, firstDay: Date, days: Int) {
        self.people = Array(people.prefix(10))
        faces = self.people.map { Face($0, decisions) }
        let start = max(0, days - weeks * 7)
        weekly = self.people.map { p in
            (0..<weeks).map { w in
                var sum = 0.0
                for d in (start + w * 7)..<min(days, start + (w + 1) * 7) where d < p.daily.count { sum += Double(p.daily[d]) }
                return sum
            }
        }
        for w in stride(from: 0, to: weeks, by: 13) {
            let date = firstDay.addingTimeInterval(Double(start + w * 7) * 86400 + 43200)
            months.append((w, date.formatted(.dateTime.month(.abbreviated))))
        }
    }

    var footer: String { "53 weeks of one-to-one messages" }
    /// The ribbons sweep in, then hold so they can be read.
    var storySeconds: Double { 8 }
    var detailKey: String { hovered.map { "row\($0)" } ?? "none" }
    var selectedPersonID: String? { hovered.map { people[$0].id } }
    var detail: Detail? {
        guard let h = hovered else { return nil }
        let total = Int(weekly[h].reduce(0, +)), busiest = Int(weekly[h].max() ?? 0), quiet = weekly[h].filter { $0 == 0 }.count
        var rows = [Detail.Row(label: "Messages", value: "\(total.formatted()) in 53 weeks"),
                    Detail.Row(label: "Busiest week", value: "\(busiest.formatted()) messages")]
        if faces[h].standing != .inMemory { rows.append(.init(label: "Weeks we talked", value: "\(weeks - quiet) of 53")) }
        return Detail(title: people[h].name, subtitle: faces[h].standing == .inMemory ? "In memory" : faces[h].relationship.label, rows: rows)
    }

    func advance(by step: Double) { time += min(0.05, max(0, step)) }
    func hover(_ p: CGPoint?) {
        guard let p, p.x > 20, p.x < 590 else { hovered = nil; return }
        let r = Int(((p.y - top) / row).rounded())
        hovered = r >= 0 && r < people.count && abs(p.y - (top + Double(r) * row)) < 20 ? r : nil
    }

    private func x(_ i: Int) -> Double { x0 + (x1 - x0) * Double(i) / Double(weeks - 1) }
    private func h(_ r: Int, _ i: Int) -> Double { min(19, sqrt(weekly[r][i]) * 1.55) }

    private let identity = UUID().uuidString

    /// One person's ribbon as triangles: the outline eased between weeks, filled, with a soft glow beyond each edge.
    private func ribbon(_ r: Int, _ y: Double, _ c: RGB) -> [(Double, Double, RGBA)] {
        var outline: [(Double, Double)] = []
        let steps = 5
        for i in 0..<(weeks - 1) {
            for k in 0..<steps {
                let u = Double(k) / Double(steps), smooth = u * u * (3 - 2 * u)
                outline.append((x(i) + (x(i + 1) - x(i)) * u, h(r, i) + (h(r, i + 1) - h(r, i)) * smooth))
            }
        }
        outline.append((x(weeks - 1), h(r, weeks - 1)))
        let body = c.c(0.78), edge = c.c(0.34), none = c.c(0), spread = 8.0
        var corners: [(Double, Double, RGBA)] = []
        corners.reserveCapacity(outline.count * 18)
        for i in 0..<(outline.count - 1) {
            let a = outline[i], b = outline[i + 1]
            func band(_ ya0: Double, _ ya1: Double, _ yb0: Double, _ yb1: Double, _ c0: RGBA, _ c1: RGBA) {
                corners.append((a.0, ya0, c0)); corners.append((b.0, yb0, c0)); corners.append((a.0, ya1, c1))
                corners.append((b.0, yb0, c0)); corners.append((b.0, yb1, c1)); corners.append((a.0, ya1, c1))
            }
            band(y - a.1 - spread, y - a.1, y - b.1 - spread, y - b.1, none, edge)          // glow above
            band(y - a.1, y + a.1, y - b.1, y + b.1, body, body)                              // the ribbon
            band(y + a.1, y + a.1 + spread, y + b.1, y + b.1 + spread, edge, none)          // glow below
        }
        return corners
    }

    func paint(_ p: Painter, _ options: DrawOptions) {
        let reveal = x0 + (x1 - x0 + 40) * min(1, time / 2.6)
        for r in people.indices {
            let y = top + Double(r) * row, c = Pal.series[r % Pal.series.count]
            let dim = hovered != nil && hovered != r ? 0.35 : 1.0
            let text = faces[r].label(options.everyoneNamed && options.names != .full ? .first : options.names) ?? String(r + 1)
            // The margin holds about 13 characters at full size; longer names shrink a little, then lose their surname.
            let shown = text.count > 19 ? faces[r].first : text
            p.text(shown, x0 - 14, y, .sans(shown.count > 13 ? 9.5 : 12), Pal.paper.c(0.85 * dim), anchor: .trailing)
            p.line(x0, y, x1, y, width: 1, c.c(0.16), round: false)

            let pulse = 0.9 + sin(time * 0.9 + Double(r)) * 0.1
            p.save()
            p.clip(CGRect(x: 0, y: 0, width: reveal, height: 540))
            p.additive = true
            p.opacity *= pulse * dim
            // The ribbon's shape never changes, so it lives on the GPU; only its brightness moves.
            p.stored("ribbon-\(identity)-\(r)") { ribbon(r, y, c) }
            p.restore()
        }
        for (w, name) in months {
            p.text(name, x(w), top + 10 * row - 8, .sans(10), Pal.quiet.c())
        }
    }
}
