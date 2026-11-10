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
    var framesPerSecond: Double { time < 3.2 ? 60 : 15 }      // still, once the ribbons have swept in
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

    func draw(_ g: inout GraphicsContext, _ options: DrawOptions) {
        g.fill(Path(CGRect(x: 0, y: 0, width: 600, height: 540)), with: .color(Pal.ground.color()))
        let reveal = x0 + (x1 - x0 + 40) * min(1, time / 2.6)
        for r in people.indices {
            let y = top + Double(r) * row, c = Pal.series[r % Pal.series.count]
            let dim = hovered != nil && hovered != r ? 0.35 : 1.0
            let text = faces[r].label(options.everyoneNamed && options.names != .full ? .first : options.names) ?? String(r + 1)
            // The margin holds about 13 characters at full size; longer names shrink a little, then lose their surname.
            let shown = text.count > 19 ? faces[r].first : text
            g.label(shown, at: pt(x0 - 14, y), font: sans(shown.count > 13 ? 9.5 : 12), color: Pal.paper.color(0.85 * dim), anchor: .trailing)
            var line = Path(); line.move(to: pt(x0, y)); line.addLine(to: pt(x1, y))
            g.stroke(line, with: .color(c.color(0.16)), lineWidth: 1)

            var ribbon = Path()
            ribbon.move(to: pt(x0, y))
            ribbon.addLine(to: pt(x(0), y - h(r, 0)))
            for i in 1..<weeks {
                let mid = (x(i - 1) + x(i)) / 2
                ribbon.addCurve(to: pt(x(i), y - h(r, i)), control1: pt(mid, y - h(r, i - 1)), control2: pt(mid, y - h(r, i)))
            }
            ribbon.addLine(to: pt(x1, y))
            ribbon.addLine(to: pt(x(weeks - 1), y + h(r, weeks - 1)))
            for i in stride(from: weeks - 2, through: 0, by: -1) {
                let mid = (x(i + 1) + x(i)) / 2
                ribbon.addCurve(to: pt(x(i), y + h(r, i)), control1: pt(mid, y + h(r, i + 1)), control2: pt(mid, y + h(r, i)))
            }
            ribbon.closeSubpath()

            var layer = g
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: reveal, height: 540)))
            layer.blendMode = .plusLighter
            layer.addFilter(.shadow(color: c.color(0.9 * dim), radius: 7))
            let pulse = 0.9 + sin(time * 0.9 + Double(r)) * 0.1
            layer.fill(ribbon, with: .color(c.color(0.78 * pulse * dim)))
        }
        for (w, name) in months {
            g.label(name, at: pt(x(w), top + 10 * row - 8), font: sans(10), color: Pal.quiet.color())
        }
    }
}
