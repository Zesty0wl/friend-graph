import SwiftUI

@main
struct FriendGraphApp: App {
    @State private var model = AppModel()
    @State private var narrator = Narrator()

    var body: some Scene {
        Window("Friend Graph", id: "main") {
            RootView()
                .environment(model)
                .environment(narrator)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Picture") {
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .disabled(model.phase != .main)
                }
                Divider()
                Button("Make My Film…") { model.showFilm = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.phase != .main)
                Button("Share…") { model.showShare = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.phase != .main)
                Button("Edit People…") { model.phase = .confirm }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.phase != .main)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    var body: some View {
        ZStack {
            Pal.ground.color().ignoresSafeArea()
            if underTest {
                EmptyView()
            } else {
                switch model.phase {
                case .welcome: WelcomeView()
                case .access: AccessView()
                case .reading: ReadingView()
                case .confirm: ConfirmView()
                case .main: MainView()
                case .failed(let message): FailedView(message: message)
                }
            }
        }
        .task {
            guard !underTest else { return }
            if let at = CommandLine.arguments.firstIndex(of: "--probe"), at + 1 < CommandLine.arguments.count {
                // Reports which sources this app can read with the permissions it has right now.
                let home = NSHomeDirectory()
                let sources = [
                    ("Messages", GraphReader.messages),
                    ("Apple Intelligence log", GraphReader.platform + "/Artifacts/siri/remembers/view.db"),
                    ("Apple Intelligence graph", GraphReader.platform + "/graph.db"),
                    ("WhatsApp", GraphReader.whatsApp + "/ChatStorage.sqlite"),
                    ("Call history", home + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"),
                    ("Contacts files", home + "/Library/Application Support/AddressBook/AddressBook-v22.abcddb"),
                ]
                let lines = sources.map { "\($0.0): \(Database($0.1) != nil ? "readable" : "blocked")" }
                try? lines.joined(separator: "\n").write(toFile: CommandLine.arguments[at + 1], atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if let directory = Snapshot.requestedDirectory {
                await Snapshot.run(into: directory, model: model)
                NSApp.terminate(nil)
            } else if CommandLine.arguments.contains("--sample") {
                // For looking at a particular screen with made-up people:
                //   --sample [--main] [--tab circle|journey|year|iris] [--share]
                let args = CommandLine.arguments
                model.useSample()
                NSApp.activate(ignoringOtherApps: true)
                if let at = args.firstIndex(of: "--size"), at + 1 < args.count {
                    let parts = args[at + 1].split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2, let window = NSApp.windows.first {
                        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                        window.center()
                    }
                }
                if args.contains("--main") { model.confirm(model.decisions) }
                if let at = args.firstIndex(of: "--tab"), at + 1 < args.count, let tab = Tab(rawValue: args[at + 1]) { model.tab = tab }
                if args.contains("--share") { model.showShare = true }
                if args.contains("--film-sheet") { model.showFilm = true }
            } else if UserDefaults.standard.bool(forKey: "hasStarted"), GraphReader.hasAccess() {
                model.read()        // returning owner: straight to their pictures
            }
        }
    }
}
