import SwiftUI

/// The shared look of the first-run screens: one column, a serif headline, plain words.
private struct Page<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(title)
                .font(serif(44))
                .foregroundStyle(Pal.paper.color())
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Words: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(sans(15))
            .foregroundStyle(Pal.soft.color())
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(title: "See who is really in your circle") {
            Words("Your Mac already knows who you talk to, how often, and how quickly you each reply. Friend Graph turns that into pictures of the people closest to you.")
            Words("Everything is worked out on this Mac. Nothing is uploaded, and nothing is shared unless you choose to share a picture.")
            HStack(spacing: 12) {
                Button("Get started") {
                    UserDefaults.standard.set(true, forKey: "hasStarted")
                    model.begin()
                }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Try it with made-up people") { model.useSample() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(.top, 8)
        }
    }
}

struct AccessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(title: "Friend Graph needs your permission") {
            Words("Messages, WhatsApp and the Mac's own record of who you talk to are kept in protected folders. To read them, Friend Graph needs Full Disk Access.")
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open Privacy & Security settings with the button below.")
                step(2, "Turn on Friend Graph in the Full Disk Access list.")
                step(3, "Come back here. macOS may ask to reopen the app.")
            }
            Words("It reads who and when, never what was said, and it only reads. You can turn access off again at any time.")
            HStack(spacing: 12) {
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                    .buttonStyle(PrimaryButtonStyle())
                Button("I've turned it on") { model.begin() }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("Try it with made-up people") { model.useSample() }
                    .buttonStyle(.link)
            }
            .padding(.top, 8)
        }
        // Coming back from System Settings: check again without making the owner press anything.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if GraphReader.hasAccess() { model.read() }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(serif(20)).foregroundStyle(Pal.amber.color()).frame(width: 18, alignment: .leading)
            Text(text).font(sans(15)).foregroundStyle(Pal.paper.color())
        }
    }
}

struct ReadingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ProgressRings()
                .frame(width: 200, height: 200)
                .accessibilityHidden(true)
            Text(model.progress)
                .font(serif(30))
                .foregroundStyle(Pal.paper.color())
            Text("This stays on your Mac.")
                .font(sans(13))
                .foregroundStyle(Pal.quiet.color())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Three rings that breathe while the Mac is being read.
private struct ProgressRings: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { g, size in
                let t = timeline.date.timeIntervalSinceReferenceDate, c = size.width / 2
                for (i, colour) in [Pal.amber, Pal.rose, Pal.violet].enumerated() {
                    let r = 30 + Double(i) * 28 + sin(t * 1.4 - Double(i) * 0.7) * 4
                    let start = t * (0.9 - Double(i) * 0.25) + Double(i)
                    g.stroke(arc(c, c, r, start, start + TAU * 0.78), with: .color(colour.color(0.9)), style: StrokeStyle(lineWidth: 3.2 - Double(i) * 0.5, lineCap: .round))
                }
                g.fill(circle(c, c, 9 + sin(t * 1.4) * 1.5), with: .color(Pal.core.color()))
            }
        }
    }
}

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        Page(title: "There is nothing to show yet") {
            Words(message)
            HStack(spacing: 12) {
                Button("Try again") { model.begin() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Try it with made-up people") { model.useSample() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
}

/// The one amber button on each screen. Drawn by hand so it keeps its colour when the window is in the background.
struct PrimaryButtonStyle: ButtonStyle {
    var large = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(sans(large ? 14 : 13, .medium))
            .foregroundStyle(RGB(26, 18, 8).color())
            .padding(.horizontal, large ? 18 : 12).padding(.vertical, large ? 8 : 5)
            .background(Capsule().fill(Pal.amber.color(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}
