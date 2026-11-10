import SwiftUI
import UniformTypeIdentifiers

/// One sheet for every picture: a preview of exactly what will leave the Mac, the privacy
/// choices, and three ways out. Names and photos start hidden.
struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tab: Tab

    @AppStorage("shareNames") private var names: NameStyle = .initials
    @AppStorage("sharePhotos") private var photos = false
    @State private var asVideo = false
    /// Chosen video length in seconds; zero means the whole story.
    @State private var videoLength = 0.0
    @State private var keepRecent = true
    @State private var story = 10.0
    @State private var tall = false
    @State private var preview: CGImage?
    @State private var working: Double?
    @State private var message = ""

    private var request: Exporter.Request {
        .init(tab: tab, names: names, photos: photos, tall: tall, videoLimit: videoLength > 0 ? videoLength : nil, keepRecent: keepRecent)
    }
    private var seconds: Double { videoLength > 0 ? min(videoLength, story) : story }
    private var isLong: Bool { story > Exporter.comfortableSeconds }

    private func spoken(_ seconds: Double) -> String {
        let total = Int(seconds.rounded()), minutes = total / 60, rest = total % 60
        if minutes == 0 { return "\(total) seconds" }
        let lead = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return rest == 0 ? lead : "\(lead) \(rest) seconds"
    }
    private var hasPeople: Bool { tab != .iris }

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ZStack {
                Pal.ground.color()
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .accessibilityLabel("Preview of the picture that will be shared")
                }
            }
            .frame(width: 300, height: tall ? 533 : 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 16) {
                Text("Share this picture").font(serif(28)).foregroundStyle(Pal.paper.color())
                if hasPeople {
                    option("Names") {
                        Picker("Names", selection: $names) { ForEach(NameStyle.allCases) { Text($0.label).tag($0) } }
                    }
                    option("Photos") {
                        Picker("Photos", selection: $photos) { Text("Show").tag(true); Text("Hide").tag(false) }
                    }
                }
                option("As") {
                    Picker("As", selection: $asVideo) { Text("Picture").tag(false); Text("Video, \(spoken(seconds))").tag(true) }
                }
                // A long story gets a choice of how much to share, and which end to keep.
                if asVideo && isLong {
                    HStack(spacing: 10) {
                        Text("Length").font(sans(13)).foregroundStyle(Pal.soft.color()).frame(width: 60, alignment: .leading)
                        Picker("Length", selection: $videoLength) {
                            Text("The whole story, \(spoken(story))").tag(0.0)
                            ForEach([90.0, 60.0, 30.0, 15.0].filter { $0 < story }, id: \.self) { Text(spoken($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if videoLength > 0 {
                        option("Keep") {
                            Picker("Keep", selection: $keepRecent) { Text("The most recent").tag(true); Text("The beginning").tag(false) }
                        }
                    }
                    Text(videoLength > 0
                         ? "Your story runs \(spoken(story)). This video keeps \(keepRecent ? "the last" : "the first") \(spoken(seconds)) of it."
                         : "Your story runs \(spoken(story)), which some apps will cut short or split.")
                        .font(sans(12)).foregroundStyle(Pal.amber.color()).fixedSize(horizontal: false, vertical: true)
                }
                option("Shape") {
                    Picker("Shape", selection: $tall) { Text("Square").tag(false); Text("Tall, for stories").tag(true) }
                }
                Text(hasPeople
                     ? "Nothing leaves this Mac until you press a button below. Anyone you left out when setting up is never included."
                     : "Nothing leaves this Mac until you press a button below. This picture names parts of macOS, not people.")
                    .font(sans(12)).foregroundStyle(Pal.quiet.color()).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let working {
                    ProgressView(value: working) { Text("Making the video").font(sans(12)) }
                } else if !message.isEmpty {
                    Text(message).font(sans(12)).foregroundStyle(Pal.amber.color())
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Copy") { Task { await deliver(.copy) } }
                    Button("Save…") { Task { await deliver(.save) } }
                    Button("Share…") { Task { await deliver(.share) } }
                        .buttonStyle(PrimaryButtonStyle(large: false))
                }
                .disabled(working != nil)
            }
            .frame(width: 400)
        }
        .padding(24)
        .frame(height: tall ? 581 : (asVideo && isLong ? 480 : 400))
        .background(RGB(20, 20, 28).color())
        .preferredColorScheme(.dark)
        .onAppear {
            story = Exporter.storySeconds(tab, model: model)
            // A long story starts on a length most places accept; the owner can change it.
            if story > Exporter.comfortableSeconds { videoLength = [60.0, 30, 15].first { $0 < story } ?? 0 }
            if CommandLine.arguments.contains("--as-video") { asVideo = true }
            render()
        }
        .onChange(of: request) { render() }
    }

    private func option<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(sans(13)).foregroundStyle(Pal.soft.color()).frame(width: 60, alignment: .leading)
            control().pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func render() { preview = Exporter.picture(request, model: model) }

    private enum Route { case copy, save, share }

    private func deliver(_ route: Route) async {
        message = ""
        do {
            let url: URL
            if asVideo {
                working = 0
                defer { working = nil }
                url = try await Exporter.video(request, model: model) { working = $0 }
            } else {
                guard let image = Exporter.picture(request, model: model), let data = Exporter.png(image) else { throw Exporter.Failure.nothingToDraw }
                url = Exporter.temporaryURL(request, video: false)
                try data.write(to: url, options: .atomic)
            }
            switch route {
            case .copy:
                let board = NSPasteboard.general
                board.clearContents()
                if asVideo { board.writeObjects([url as NSURL]) } else if let image = NSImage(contentsOf: url) { board.writeObjects([image]) }
                message = asVideo ? "Video copied." : "Picture copied."
            case .save:
                let panel = NSSavePanel()
                panel.allowedContentTypes = [asVideo ? .mpeg4Movie : .png]
                panel.nameFieldStringValue = url.lastPathComponent
                if panel.runModal() == .OK, let target = panel.url {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                    message = "Saved."
                }
            case .share:
                if let view = NSApp.keyWindow?.contentView {
                    let picker = NSSharingServicePicker(items: [url])
                    picker.show(relativeTo: CGRect(x: view.bounds.maxX - 80, y: 30, width: 1, height: 1), of: view, preferredEdge: .maxY)
                }
            }
        } catch is CancellationError {
        } catch {
            message = "That did not work: \(error.localizedDescription)"
        }
    }
}
