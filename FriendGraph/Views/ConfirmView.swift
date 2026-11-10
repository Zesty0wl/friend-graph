import SwiftUI

/// The one screen where the owner checks what we worked out: who each person is to them, and
/// whether they belong in the pictures. Nothing is shown anywhere else until this is confirmed.
struct ConfirmView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Decisions()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Have we got this right?")
                        .font(serif(40))
                        .foregroundStyle(Pal.paper.color())
                    Text("These are the people your Mac shows you talking to most, with our best guess at who each one is to you. Change anything that is wrong.")
                        .font(sans(14)).foregroundStyle(Pal.soft.color()).lineSpacing(3)
                    Text("If someone has died, choose In memory. They keep their place in your pictures as a steady light, and are never described as having gone quiet. Choose Leave out for anyone you would rather not see; they will not appear in any picture, or in anything you share.")
                        .font(sans(14)).foregroundStyle(Pal.soft.color()).lineSpacing(3)

                    section("The people I talk to", people: model.dataset?.scored ?? [], guessable: true)
                    if let earlier = model.dataset?.earlier, !earlier.isEmpty {
                        section("From earlier years", people: earlier, guessable: false)
                        Text("These people are not among your closest today, but were at some point. They only appear in the moving timeline.")
                            .font(sans(12)).foregroundStyle(Pal.quiet.color())
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(Pal.paper.color(0.09))
            HStack {
                Text(summary).font(sans(12)).foregroundStyle(Pal.quiet.color())
                Spacer()
                Button("Looks right") { model.confirm(draft) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 36).padding(.vertical, 14)
        }
        .onAppear { draft = model.decisions }
    }

    private var summary: String {
        let all = (model.dataset?.scored ?? []) + (model.dataset?.earlier ?? [])
        let left = all.filter { draft.standing(of: $0) == .leftOut }.count
        let memory = all.filter { draft.standing(of: $0) == .inMemory }.count
        var parts = ["\(all.count - left) people in your pictures"]
        if memory > 0 { parts.append("\(memory) in memory") }
        if left > 0 { parts.append("\(left) left out") }
        return parts.joined(separator: " · ") + ". Kept on this Mac only."
    }

    @ViewBuilder
    private func section(_ title: String, people: [Person], guessable: Bool) -> some View {
        Text(title.uppercased())
            .font(sans(11, .medium)).tracking(1.2)
            .foregroundStyle(Pal.quiet.color())
            .padding(.top, 14)
        VStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                row(person, guessable: guessable)
                if index < people.count - 1 { Divider().overlay(Pal.paper.color(0.07)) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Pal.paper.color(0.04)))
    }

    private func row(_ person: Person, guessable: Bool) -> some View {
        let standing = draft.standing(of: person)
        return HStack(spacing: 14) {
            Avatar(person: person, size: 40)
                .opacity(standing == .leftOut ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(sans(15, .medium)).foregroundStyle(Pal.paper.color(standing == .leftOut ? 0.45 : 1))
                Text(caption(person, guessable: guessable)).font(sans(12)).foregroundStyle(Pal.quiet.color())
            }
            Spacer(minLength: 12)
            if guessable {
                Picker("Who \(person.first) is to me", selection: Binding(
                    get: { draft.relationship(of: person) },
                    set: { draft.relationship[person.id] = $0 })) {
                    ForEach(Relationship.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 170)
                .disabled(standing == .leftOut)
            }
            Picker("Whether \(person.first) appears", selection: Binding(
                get: { draft.standing(of: person) },
                set: { draft.standing[person.id] = $0 })) {
                ForEach(Standing.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func caption(_ p: Person, guessable: Bool) -> String {
        guard guessable else {
            let from = p.firstActiveDay.flatMap { model.dataset?.firstDay.addingTimeInterval(Double($0) * 86400) }
            let to = p.lastActiveDay.flatMap { model.dataset?.firstDay.addingTimeInterval(Double($0) * 86400) }
            if let from, let to { return "\(from.formatted(.dateTime.year())) to \(to.formatted(.dateTime.year()))" }
            return "\(p.messages.formatted()) messages"
        }
        var parts = ["\(p.messages.formatted()) messages this year"]
        if p.calls > 0 { parts.append("\(p.calls) calls") }
        if p.familySharing { parts.append("Family Sharing") }
        return parts.joined(separator: " · ")
    }
}

/// A round photo, or initials on a quiet disc.
struct Avatar: View {
    let person: Person
    let size: Double

    var body: some View {
        Group {
            if let photo = person.photo, let image = Face.square(photo) {
                image.resizable()
            } else {
                ZStack {
                    Pal.amber.color(0.16)
                    Text(person.initials.first.map { $0.isLetter } == true ? person.initials : "#")
                        .font(serif(size * 0.42)).foregroundStyle(Pal.amber.color())
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
