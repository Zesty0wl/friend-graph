import SwiftUI

/// Builds a picture from the owner's data and choices. The live window and the exporter both use
/// this, so a shared picture is drawn by exactly the same code as the one on screen.
@MainActor
enum SceneBuilder {
    static func make(_ tab: Tab, model: AppModel, live: Bool) -> (any VisualScene)? {
        guard let data = model.dataset else { return nil }
        let people = model.circlePeople, decisions = model.decisions
        switch tab {
        case .circle:
            return CircleScene(people: people, decisions: decisions, scoredCount: data.scored.count, othersKnown: data.othersKnown,
                               onRing: live ? { [weak model] id, ring in model?.setRing(ring, for: id) } : { _, _ in })
        case .journey:
            let leading = Array(people.prefix(10))
            return JourneyScene(cast: leading + model.earlierPeople, leading: leading.count, decisions: decisions, firstDay: data.firstDay, days: data.days)
        case .year:
            return YearScene(people: people, decisions: decisions, firstDay: data.firstDay, days: data.days)
        case .iris:
            return data.watch.map { IrisScene($0) }
        }
    }

    static func title(_ tab: Tab) -> String {
        switch tab {
        case .circle: return "My circle"
        case .journey: return "My year, and who was alongside"
        case .year: return "A year with my circle"
        case .iris: return "What my Mac is working out about me"
        }
    }

    static func blurb(_ tab: Tab) -> String {
        switch tab {
        case .circle: return "Everyone here is someone I really talk to. The nearer and warmer they are, the closer we are, and a thicker strand means more messages. The lights are messages going each way. Drag to spin it, drag someone closer or further away, and point at anyone to see the two of us."
        case .journey: return "I'm the bright dot. People move in close during the weeks we talked, and drift out when we didn't."
        case .year: return "One line per person, closest at the top. It swells in the weeks we talked most and thins out when we went quiet. Point at a line to see the numbers."
        case .iris: return "Every strand is one thing macOS keeps up to date about me. Longer strands draw on more sources, brighter ones ran more recently, and a bigger dot at the tip holds more. A hollow tip is empty."
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var scenes: [Tab: any VisualScene] = [:]
    @State private var builtRevision = -1
    @State private var detail: Detail?
    @State private var detailKey = ""
    @State private var personID: String?
    @State private var footer = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Group {
                if let scene = scenes[model.tab] {
                    MetalSceneView(scene: scene, options: DrawOptions(names: .first, photos: true)) { refresh(scene) }
                        .id(model.tab)
                        .accessibilityLabel(SceneBuilder.title(model.tab))
                } else {
                    Text(model.tab == .iris ? "This Mac has no record of what Apple Intelligence keeps up to date, so there is nothing to draw here." : "Nothing to show.")
                        .font(sans(14)).foregroundStyle(Pal.soft.color())
                        .frame(maxWidth: 360).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)

            Rectangle().fill(Pal.paper.color(0.09)).frame(width: 1)

            SidePanel(panel: panel, footer: footer, notes: (model.dataset?.isSample == true ? ["These are made-up people."] : []) + (model.dataset?.notes ?? []))
                .frame(width: 372)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Picture", selection: $model.tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit People") { model.phase = .confirm }
                    .help("Change who is in your pictures")
                Button("My Film") { model.showFilm = true }
                    .help("Make a short film of your year")
                Button("Share") { model.showShare = true }
                    .buttonStyle(PrimaryButtonStyle(large: false))
                    .disabled(scenes[model.tab] == nil)
                    .help("Share this picture")
            }
        }
        .sheet(isPresented: $model.showShare) { ShareSheet(tab: model.tab).environment(model) }
        .sheet(isPresented: $model.showFilm) { FilmSheet().environment(model) }
        .onAppear(perform: build)
        .onChange(of: model.revision) { build() }
        .onChange(of: model.tab) { detail = nil; personID = nil; detailKey = ""; if let s = scenes[model.tab] { footer = s.footer } }
    }

    /// What the panel shows: the person or strand under the pointer, or the picture as a whole.
    private var panel: Panel {
        if let id = personID, let person = model.dataset?.person(id),
           let made = Insights.person(person, subtitle: model.tab == .circle ? (detail?.subtitle ?? "") : model.decisions.relationship(of: person).label, model: model) {
            return made
        }
        if let detail, model.tab == .iris { return Insights.strand(detail) }
        return Insights.overview(model.tab, model: model) ?? Panel(title: SceneBuilder.title(model.tab), subtitle: SceneBuilder.blurb(model.tab))
    }

    private func build() {
        guard builtRevision != model.revision else { return }
        builtRevision = model.revision
        var made: [Tab: any VisualScene] = [:]
        for tab in Tab.allCases { made[tab] = SceneBuilder.make(tab, model: model, live: true) }
        scenes = made
        detail = nil; personID = nil; detailKey = ""
        footer = made[model.tab]?.footer ?? ""
        // For looking at a selected person without a pointer: --select 3
        if let at = CommandLine.arguments.firstIndex(of: "--select"), at + 1 < CommandLine.arguments.count, let index = Int(CommandLine.arguments[at + 1]),
           let circle = made[.circle] as? CircleScene {
            circle.select(index: index)
            refresh(circle)
        }
        if let at = CommandLine.arguments.firstIndex(of: "--strand"), at + 1 < CommandLine.arguments.count, let iris = made[.iris] as? IrisScene {
            iris.select(named: CommandLine.arguments[at + 1])
            if model.tab == .iris { refresh(iris) }
        }
    }

    private func refresh(_ scene: any VisualScene) {
        let key = scene.detailKey
        if key != detailKey { detailKey = key; detail = scene.detail; personID = scene.selectedPersonID }
        let text = scene.footer
        if text != footer { footer = text }
    }
}
