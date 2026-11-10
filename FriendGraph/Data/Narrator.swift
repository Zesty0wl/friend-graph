import Foundation
import FoundationModels
import Observation

/// Writes a sentence or two about a set of facts, using the language model built into macOS.
/// It runs entirely on this Mac. The model is given only facts already worked out from the
/// owner's data, and is told to add nothing; if it is unavailable, the panel shows a plain
/// sentence of our own.
@MainActor
@Observable
final class Narrator {
    /// Finished stories, by the panel's story key.
    private(set) var stories: [String: String] = [:]
    @ObservationIgnored private var inFlight = Set<String>()

    static let instructions = """
        You polish captions for a personal app that shows its owner who they talk to most. \
        You are given a few facts, each already a sentence written by the owner in the first person. \
        Rewrite them as one smooth caption of two sentences, keeping the first person. \
        Keep the meaning of every fact exactly. Keep every name and every number exactly as given. \
        Do not add anything that is not in the facts: no extra words about how often something happens, no feelings, no reasons, no conclusions. \
        Never change who is doing something. \
        Plain British English. No exclamation marks, no emoji, no lists, no questions, no quotation marks. 45 words at most.
        """

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why the model can't be used, in words for the owner. Nil when it can.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to have these notes written for you."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready on this Mac."
        case .unavailable: return nil
        }
    }

    /// Writes the story for a panel if it has not been written yet. Safe to call repeatedly.
    func write(_ panel: Panel) async {
        guard let key = panel.storyKey, !panel.fixedStory, !panel.facts.isEmpty, stories[key] == nil, !inFlight.contains(key), isAvailable else { return }
        // Wait a moment, so sweeping the pointer across a dozen people does not queue a dozen stories.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let facts = Array(panel.facts.prefix(3))
            let prompt = "Facts:\n" + facts.map { "- " + $0 }.joined(separator: "\n") + "\n\nRewrite these as the caption."
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120))
            if let text = Self.tidy(response.content), Self.faithful(text, to: facts) { stories[key] = text }
        } catch {
            // Guardrails, a busy model or a cancelled request: the plain sentence stays.
        }
    }

    /// A caption is only shown if it invents nothing we can detect: every number in it must come from
    /// the facts, every name must still be there, and it must not claim a frequency the facts do not.
    static func faithful(_ text: String, to facts: [String]) -> Bool {
        let source = facts.joined(separator: " ")
        func numbers(_ s: String) -> Set<String> {
            var out = Set<String>(), current = ""
            for ch in s + " " {
                if ch.isNumber { current.append(ch) } else if ch == "," && !current.isEmpty { continue } else { if !current.isEmpty { out.insert(current) }; current = "" }
            }
            return out
        }
        guard numbers(text).isSubset(of: numbers(source)) else { return false }
        // Names: capitalised words in the facts, other than sentence openers we use ourselves.
        let plain = Set(["I", "My", "Our", "We", "Of", "They", "The", "Over", "It", "Mac", "Siri", "Apple", "Intelligence"])
        let names = Set(source.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { ($0.first?.isUppercase ?? false) && !plain.contains($0) })
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard names.isSubset(of: words) else { return false }
        let lowered = text.lowercased(), sourceLowered = source.lowercased()
        for claim in ["every day", "everyday", "daily", "always", "never", "constantly", "all the time", "every week", "most time", "each day"] where lowered.contains(claim) && !sourceLowered.contains(claim) {
            return false
        }
        return true
    }

    /// Rejects anything that is not a short piece of plain prose.
    static func tidy(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        text = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        guard text.count >= 20, text.count <= 420, !text.contains("- "), !text.hasPrefix("Facts"), text.hasSuffix(".") else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
