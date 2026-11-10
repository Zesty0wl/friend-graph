import Foundation

/// How someone is related to the owner. Guessed first, then confirmed or corrected by the owner.
enum Relationship: String, Codable, CaseIterable, Identifiable, Sendable {
    case partner, parent, child, sibling, family, friend, colleague, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .partner: return "Partner"
        case .parent: return "Parent"
        case .child: return "Child"
        case .sibling: return "Brother or sister"
        case .family: return "Family"
        case .friend: return "Friend"
        case .colleague: return "Colleague"
        case .other: return "Someone I know"
        }
    }
}

/// Whether someone appears in the pictures. "In memory" keeps a person who has died in their place,
/// shown as a steady light, and never describes them as having gone quiet.
enum Standing: String, Codable, CaseIterable, Identifiable, Sendable {
    case included, inMemory, leftOut
    var id: String { rawValue }
    var label: String {
        switch self {
        case .included: return "In my circle"
        case .inMemory: return "In memory"
        case .leftOut: return "Leave out"
        }
    }
}

struct Person: Identifiable, Sendable {
    let id: String
    var name: String
    var photo: Data?
    var familySharing = false
    var guess: Relationship = .friend
    /// Our closeness score, 0 to 1. Nil for people who only appear in earlier years.
    var score: Double?
    var messages = 0
    var incoming = 0
    var outgoing = 0
    var myReplyMinutes: Double?
    var theirReplyMinutes: Double?
    var calls = 0
    var callMinutes = 0.0
    /// Messages per day, aligned with `Dataset.firstDay`.
    var daily: [UInt16] = []

    var parts: [String] { name.replacingOccurrences(of: "~", with: "").split(separator: " ").map(String.init) }
    var first: String { parts.first ?? "?" }
    var initials: String {
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
    var firstActiveDay: Int? { daily.firstIndex { $0 > 0 } }
    var lastActiveDay: Int? { daily.lastIndex { $0 > 0 } }
}

/// One thing macOS keeps up to date about the owner (a "view" over the knowledge graph).
struct WatchView: Codable, Sendable {
    struct Listener: Codable, Sendable {
        var type: String
        var ref: String
        var schedule: String
    }
    var name: String
    var cat: Int
    var what: String
    var target: String
    var listens: [Listener]
    var last: Int
    /// How many records this view holds right now. Nil when it does not keep a table we can count.
    var rows: Int?
}

struct WatchData: Codable, Sendable {
    var captured: Int
    var cats: [String]
    var views: [WatchView]
}

struct Dataset: Sendable {
    /// People with a two-way conversation, closest first.
    var scored: [Person]
    /// People who mattered in earlier years but are not among the scored people today.
    var earlier: [Person]
    /// How many more people the Mac knows of without a real conversation.
    var othersKnown: Int
    /// Local midnight of day 0 in every `Person.daily`.
    var firstDay: Date
    var days: Int
    var watch: WatchData?
    var isSample: Bool
    var notes: [String] = []

    func person(_ id: String) -> Person? { scored.first { $0.id == id } ?? earlier.first { $0.id == id } }
}

/// What the owner told us on the confirmation screen. Stays on this Mac.
struct Decisions: Codable, Sendable, Equatable {
    var relationship: [String: Relationship] = [:]
    var standing: [String: Standing] = [:]
    /// Ring the owner dragged someone into: 0 inner circle, 1 friends, 2 people I know.
    var ring: [String: Int] = [:]
    var confirmed = false

    func standing(of p: Person) -> Standing { standing[p.id] ?? .included }
    func relationship(of p: Person) -> Relationship { relationship[p.id] ?? p.guess }
}

enum Handle {
    /// One key per person across handle formats: the last nine digits of a number, or a lowercased address.
    static func key(_ handle: String) -> String {
        let local = handle.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? handle
        let digits = local.filter { $0.isASCII && $0.isNumber }
        let undashed = local.replacingOccurrences(of: "-", with: "")
        let allDigits = !undashed.isEmpty && undashed.allSatisfy { $0.isASCII && $0.isNumber }
        if digits.count >= 9 && (handle.hasPrefix("+") || allDigits) { return String(digits.suffix(9)) }
        return handle.lowercased()
    }

    static func normalisedName(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func phone(_ raw: String) -> String { "+" + raw.filter { $0.isASCII && $0.isNumber } }
}
