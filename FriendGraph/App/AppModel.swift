import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case circle, journey, year, iris
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return "My circle"
        case .journey: return "My year"
        case .year: return "Week by week"
        case .iris: return "What my Mac knows"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case welcome, access, reading, confirm, main, failed(String) }

    var phase: Phase = .welcome
    var dataset: Dataset?
    var decisions = Decisions()
    var tab: Tab = .circle
    var progress = "Getting ready"
    var showShare = false
    /// Bumped whenever the people on screen change, so pictures are rebuilt.
    var revision = 0

    private var usingSample = false

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uk.co.bzwrd.friendgraph", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("decisions.json")
    }

    /// Called from the welcome screen.
    func begin() {
        if GraphReader.hasAccess() { read() } else { phase = .access }
    }

    func useSample() {
        usingSample = true
        dataset = SampleData.make()
        decisions = Decisions()
        // Show the "in memory" treatment in the sample.
        if let kim = dataset?.scored.first(where: { $0.name == "Kim Lowe" }) { decisions.standing[kim.id] = .inMemory }
        revision += 1
        phase = .confirm
    }

    func read() {
        usingSample = false
        phase = .reading
        progress = "Getting ready"
        let report: @Sendable (String) -> Void = { [weak self] step in Task { @MainActor in self?.progress = step } }
        Task {
            let result: Result<Dataset, Error> = await Task.detached(priority: .userInitiated) {
                Result { try GraphReader.load(progress: report) }
            }.value
            switch result {
            case .success(let data):
                dataset = data
                if let saved = try? Data(contentsOf: Self.storeURL), let decoded = try? JSONDecoder().decode(Decisions.self, from: saved) {
                    decisions = decoded
                } else { decisions = Decisions() }
                revision += 1
                phase = decisions.confirmed ? .main : .confirm
            case .failure(GraphReader.Failure.noAccess):
                phase = .access
            case .failure(GraphReader.Failure.noConversations):
                phase = .failed("Friend Graph could not find any two-way conversations in Messages or WhatsApp on this Mac.")
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func confirm(_ updated: Decisions) {
        decisions = updated
        decisions.confirmed = true
        save()
        revision += 1
        phase = .main
    }

    func setRing(_ ring: Int, for id: String) {
        decisions.ring[id] = ring
        save()
    }

    private func save() {
        guard !usingSample, let data = try? JSONEncoder().encode(decisions) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// Scored people the owner has not left out, closest first.
    var circlePeople: [Person] {
        (dataset?.scored ?? []).filter { decisions.standing(of: $0) != .leftOut }
    }
    var earlierPeople: [Person] {
        (dataset?.earlier ?? []).filter { decisions.standing(of: $0) != .leftOut }
    }
}
