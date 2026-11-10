import SwiftUI
import AVKit

/// Three quick questions, then a short film of the owner's year, made on this Mac.
struct FilmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Narrator.self) private var narrator
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case questions, making(Double), done(URL), failed(String) }

    @State private var phase: Phase = .questions
    @State private var answers = Film.Answers()
    @State private var player: AVPlayer?
    @State private var task: Task<Void, Never>?
    @State private var message = ""
    @AppStorage("filmNames") private var names: NameStyle = .full
    @AppStorage("filmPhotos") private var photos = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .questions: questions
            case .making(let progress): making(progress)
            case .done(let url): finished(url)
            case .failed(let why): failed(why)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(RGB(20, 20, 28).color())
        .preferredColorScheme(.dark)
        .onDisappear { task?.cancel(); player?.pause() }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("My year, as a film").font(serif(34)).foregroundStyle(Pal.paper.color())
            Text("Under a minute, with music, made on this Mac from the people in your circle. Three quick questions first. Skip any you like.")
                .font(sans(13)).foregroundStyle(Pal.soft.color()).lineSpacing(3).fixedSize(horizontal: false, vertical: true)

            question("Your year in a word") {
                TextField("Steady, wild, new…", text: $answers.word)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: answers.word) { answers.word = String(answers.word.prefix(24)) }
            }
            question("Someone to thank") {
                Picker("Someone to thank", selection: $answers.thanks) {
                    Text("No one in particular").tag(String?.none)
                    ForEach(model.circlePeople) { Text($0.name).tag(String?.some($0.id)) }
                }
                .labelsHidden()
            }
            question("The best moment of the year") {
                TextField("A few words, shown as you write them", text: $answers.moment)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: answers.moment) { answers.moment = String(answers.moment.prefix(90)) }
            }
            Divider().overlay(Pal.paper.color(0.09))
            HStack(spacing: 18) {
                Picker("Names", selection: $names) { Text("Full names").tag(NameStyle.full); Text("First names").tag(NameStyle.first) }.fixedSize()
                Picker("Photos", selection: $photos) { Text("Show").tag(true); Text("Hide").tag(false) }.fixedSize()
            }
            .font(sans(13))
            Text("Your answers appear in the film exactly as you type them. The captions are written by Apple Intelligence from your own figures. Nothing leaves this Mac until you share the film yourself.")
                .font(sans(12)).foregroundStyle(Pal.quiet.color()).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make my film") { make() }.buttonStyle(PrimaryButtonStyle(large: false)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func question<Content: View>(_ label: String, @ViewBuilder _ field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(sans(13, .medium)).foregroundStyle(Pal.paper.color())
            field()
        }
    }

    private func making(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Making your film").font(serif(34)).foregroundStyle(Pal.paper.color())
            ProgressView(value: progress)
            Text(progress < 0.09 ? "Writing the captions" : progress < 0.95 ? "Drawing the film" : "Adding the music")
                .font(sans(13)).foregroundStyle(Pal.soft.color())
            HStack { Spacer(); Button("Cancel") { task?.cancel(); phase = .questions } }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("My year").font(serif(34)).foregroundStyle(Pal.paper.color())
            HStack {
                Spacer()
                if let player {
                    VideoPlayer(player: player)
                        .frame(width: 270, height: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Your film")
                }
                Spacer()
            }
            if !message.isEmpty { Text(message).font(sans(12)).foregroundStyle(Pal.amber.color()) }
            HStack(spacing: 8) {
                Button("Start again") { player?.pause(); phase = .questions }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") { save(url) }
                Button("Share…") { share(url) }.buttonStyle(PrimaryButtonStyle(large: false))
            }
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The film could not be made").font(serif(30)).foregroundStyle(Pal.paper.color())
            Text(why).font(sans(13)).foregroundStyle(Pal.soft.color()).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close") { dismiss() }; Button("Try again") { phase = .questions } }
        }
    }

    private func make() {
        phase = .making(0)
        message = ""
        task = Task {
            do {
                let url = try await Exporter.film(model: model, narrator: narrator, answers: answers, options: DrawOptions(names: names == .first ? .first : .full, photos: photos, everyoneNamed: true)) { value in
                    if case .making = phase { phase = .making(value) }
                }
                guard !Task.isCancelled else { return }
                let made = AVPlayer(url: url)
                player = made
                phase = .done(url)
                made.play()
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "My year.mp4"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            message = "Saved."
        } catch { message = "That did not save: \(error.localizedDescription)" }
    }

    private func share(_ url: URL) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: CGRect(x: view.bounds.maxX - 80, y: 30, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }
}
