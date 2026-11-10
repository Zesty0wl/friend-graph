import SwiftUI

/// The panel beside each picture: a headline, a short story, the numbers that matter as large
/// figures, and a few small charts. It changes to the person or strand under the pointer.
struct SidePanel: View {
    let panel: Panel
    let footer: String
    let notes: [String]
    @Environment(Narrator.self) private var narrator

    private var written: String? { panel.fixedStory ? nil : panel.storyKey.flatMap { narrator.stories[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(panel.title)
                            .font(serif(36)).foregroundStyle(Pal.paper.color())
                            .fixedSize(horizontal: false, vertical: true)
                        Text(panel.subtitle)
                            .font(sans(12.5)).foregroundStyle(Pal.quiet.color()).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if panel.storyKey != nil { story }
                    if !panel.stats.isEmpty { figures }
                    if let split = panel.split, split.mine + split.theirs > 0 { SplitBar(mine: split.mine, theirs: split.theirs, accent: panel.accent) }
                    if let replies = panel.replies, replies.mine != nil || replies.theirs != nil { ReplyPace(mine: replies.mine, theirs: replies.theirs, accent: panel.accent) }
                    if !panel.ranking.isEmpty { ranking }
                    if panel.months.contains(where: { $0 > 0 }) {
                        MiniBars(title: "The last twelve months", values: panel.months, labels: panel.monthLabels, colour: panel.accent)
                    }
                    if panel.weekdays.contains(where: { $0 > 0 }) {
                        MiniBars(title: "By day of the week", values: panel.weekdays, labels: ["M", "T", "W", "T", "F", "S", "S"], colour: panel.accent)
                    }
                    if !panel.rows.isEmpty { rows }
                }
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.18), value: panel.title)
            }
            .scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    Text(note).font(sans(12)).foregroundStyle(Pal.amber.color()).fixedSize(horizontal: false, vertical: true)
                }
                Text(footer.uppercased())
                    .font(sans(10.5)).tracking(0.9).foregroundStyle(Pal.quiet.color()).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: panel.storyKey) { await narrator.write(panel) }
    }

    private var story: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(written ?? panel.fallback)
                .font(serif(19)).foregroundStyle(Pal.paper.color(0.92)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .id(written ?? panel.fallback)
                .transition(.opacity)
            if written != nil {
                Text("Written on this Mac by Apple Intelligence, from the figures below")
                    .font(sans(10.5)).foregroundStyle(Pal.quiet.color(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !panel.fixedStory, let reason = narrator.unavailableReason {
                Text(reason).font(sans(10.5)).foregroundStyle(Pal.quiet.color(0.8)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) { Capsule().fill(panel.accent.color(0.85)).frame(width: 2) }
        .animation(.easeInOut(duration: 0.5), value: written)
    }

    private var figures: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 16) {
            ForEach(panel.stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value)
                        .font(serif(stat.value.count > 9 ? 21 : 32)).foregroundStyle(Pal.paper.color())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(sans(11.5)).foregroundStyle(Pal.quiet.color()).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 9) {
            Heading(panel.rankingTitle)
            ForEach(panel.ranking) { bar in
                HStack(spacing: 10) {
                    Text(bar.label).font(sans(12.5)).foregroundStyle(Pal.paper.color(0.9)).lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(bar.colour.color(0.9))
                            .frame(width: max(3, geo.size.width * bar.value), height: 5)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 14)
                    Text(bar.text).font(sans(12)).foregroundStyle(Pal.soft.color()).monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(panel.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Heading(row.label)
                    Text(row.value).font(sans(13.5)).foregroundStyle(RGB(217, 214, 224).color()).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(sans(10.5, .medium)).tracking(1.1).foregroundStyle(Pal.quiet.color())
    }
}

/// Who sends more: one bar split between me and them.
private struct SplitBar: View {
    let mine: Int, theirs: Int
    let accent: RGB

    var body: some View {
        let share = Double(mine) / Double(max(1, mine + theirs))
        VStack(alignment: .leading, spacing: 7) {
            Heading("Who sends more")
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(accent.color()).frame(width: max(4, (geo.size.width - 3) * share))
                    Capsule().fill(Pal.paper.color(0.28))
                }
            }
            .frame(height: 6)
            HStack {
                Text("Me \(Int((share * 100).rounded()))%").foregroundStyle(accent.color())
                Spacer()
                Text("Them \(100 - Int((share * 100).rounded()))%").foregroundStyle(Pal.soft.color())
            }
            .font(sans(12))
        }
        .accessibilityElement(children: .combine)
    }
}

/// How quickly each of us replies. Bars are on a log scale, so a minute and an hour both read.
private struct ReplyPace: View {
    let mine: Double?, theirs: Double?
    let accent: RGB

    private func length(_ minutes: Double?) -> Double {
        guard let m = minutes else { return 0 }
        return max(0.04, min(1, log10(1 + m) / log10(1 + 240)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading("How quickly we reply")
            line("I reply in", mine, accent.color())
            line("They reply in", theirs, Pal.paper.color(0.45))
        }
    }

    private func line(_ label: String, _ minutes: Double?, _ colour: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(sans(12.5)).foregroundStyle(Pal.paper.color(0.9)).frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(colour).frame(width: max(3, geo.size.width * length(minutes)), height: 5)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            Text(minutes == nil ? "–" : minutesText(minutes).replacingOccurrences(of: "minutes", with: "min").replacingOccurrences(of: "hours", with: "hr").replacingOccurrences(of: "under a minute", with: "<1 min"))
                .font(sans(12)).foregroundStyle(Pal.soft.color()).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of small bars with a letter under each: months, or days of the week.
private struct MiniBars: View {
    let title: String
    let values: [Double]
    let labels: [String]
    let colour: RGB

    var body: some View {
        let top = max(1, values.max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            Heading(title)
            HStack(alignment: .bottom, spacing: values.count > 8 ? 5 : 9) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(colour.color(value == top ? 1 : 0.5))
                            .frame(height: max(2, 44 * value / top))
                            .frame(height: 44, alignment: .bottom)
                        Text(index < labels.count ? labels[index] : "").font(sans(10)).foregroundStyle(Pal.quiet.color())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
