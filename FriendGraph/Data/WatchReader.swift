import Foundation

/// Reads what is running over the personal knowledge graph: every named view macOS maintains,
/// what each one listens to, on what schedule, and when it last ran. This is system metadata
/// (view names, stream names, timestamps), not personal content.
enum WatchReader {
    /// Categories, in the order they sit around the iris. First matching pattern wins.
    static let categories: [(String, String)] = [
        ("People", #"person|people|entityTagging|entityAlias|handleMap|entityImportance|bidirectional|entitySummary|entitySubgraph|hasAssociation|entityRelevance"#),
        ("Faces", #"photos|visualIdentifier|phPerson"#),
        ("Places", #"^loi|GeoHash|LOIContext|WiFi|Location|semanticLocation|poiCategory"#),
        ("Right now", #"motionState|workout|soundAnalysis|nowPlaying|physicalSocial|userFocus|virtualInteractions|TimeOfDay|DayOfWeek|timeAndDate|behaviorSequence|messagingInteraction"#),
        ("Interests", #"appleMusic|sportsTeams|scoredTopics|holidayEvent"#),
        ("Events and travel", #"Flight|lifeEvent|LifeEvent|eventSubgraph"#),
        ("Apps", #"^app|Software|AppsRecentlyFocused"#),
        ("Siri and Apple Intelligence", #"siri|Siri|^SP|^ITD|^IT[A-Z]|asr|defaultResolver|languageView|inferenceFeatures"#),
    ]

    /// Plain descriptions. Apple documents none of these; each is read off the view's own name
    /// and what it subscribes to.
    static let descriptions: [String: String] = [
        "physicalSocialSignal": "Whether you are physically around other people",
        "soundAnalysisSignal": "The kinds of sound detected around you",
        "motionStateSignal": "Whether you are still, walking, running or driving",
        "motionStateDistributionSignal": "How your time splits between still, walking and driving",
        "workoutSignal": "When you are working out",
        "nowPlayingSignal": "What is playing right now",
        "userFocusComputedModeSignal": "Which Focus mode you are in",
        "virtualInteractionsDistributionSignal": "How your calls and messages are spread through the day",
        "messagingInteractionFeature": "Your messaging activity",
        "behaviorSequenceSignal": "The order you tend to do things in",
        "timeAndDateSignal": "The time and date, as context",
        "currentWiFiContext": "Which Wi-Fi network you are on",
        "currentLOIContext": "Which of your regular places you are at",
        "currentCoarseGeoHashContext": "Roughly where you are",
        "currentSpecificGeoHashContext": "Precisely where you are",
        "currentCoarseTimeOfDayContext": "Morning, afternoon, evening or night",
        "currentDayOfWeekContext": "Which day of the week it is",
        "semanticLocationSignal": "Whether you are at home, work or elsewhere",
        "poiCategorySignal": "The kind of place you are at (shop, gym, restaurant)",
        "locationSubgraphFeatures": "Facts about your places",
        "Location": "Your places",
        "peopleRelationship": "How each person is related to you",
        "entityTagging": "The relationship scorecard: mother, partner, friend, coworker",
        "personEntityTagging": "Per-person patterns that feed the relationship scorecard",
        "personEntityTaggingFacts": "Per-person facts that feed the scorecard: same surname, shared address",
        "photosPersonEntityTagging": "Patterns for people recognised in your photos",
        "personEntityRelevanceRanking": "Who matters to you right now, ranked",
        "personEntityLongTermRanking": "Who matters to you over the long run, ranked",
        "loiEntityRelevanceRanking": "Which of your places matter right now, ranked",
        "entityImportanceSignals": "Favourites, emergency contacts and Family Sharing members",
        "entityAlias": "Nicknames and other names for people",
        "entityAliasECR": "Nicknames, prepared for resolving who you mean",
        "entityAliasEuclidVDB": "Names turned into vectors, for fuzzy matching",
        "asrEntityAlias": "How names sound, for speech recognition",
        "handleMap": "Which phone numbers and addresses belong to which person",
        "phPersonIdentifierMap": "Which Photos face belongs to which person",
        "photosAutonamingView": "Suggested names for faces in Photos",
        "visualIdentifier": "Faces linked to people",
        "people": "Everyone in your graph",
        "peopleSubgraph": "Everyone in your graph, with their details",
        "Person": "People, published for other parts of the system",
        "siriPersonView": "People, as Siri sees them",
        "siriRemembers": "The log of your messages and calls (who and when, no text)",
        "defaultResolverInteractions": "Past interactions, used to guess who or what you mean",
        "personEntityHistograms": "How often you interact with each person",
        "bidirectionalPersonEntityHistograms": "Who contacts whom, in each direction",
        "photosPersonEntityHistograms": "How often each face appears",
        "loiEntityHistograms": "How often you are at each place",
        "appleMusicEventMap": "Your Apple Music plays",
        "appleMusicEventSubgraph": "Your Apple Music plays, as graph facts",
        "sportsTeams": "Sports teams, as reference knowledge",
        "holidayEvent": "Public holidays, as reference knowledge",
        "scoredTopicsFirstPartyLongTerm": "Topics you are interested in, long term",
        "scoredTopicsFirstPartyShortTerm": "Topics you are interested in lately",
        "FlightReservations": "Your flight bookings",
        "lifeEventMap": "Life events found in your data",
        "lifeEventSubgraph": "Life events, as graph facts",
        "futureLifeEventMap": "Upcoming life events",
        "futureLifeEventSubgraph": "Upcoming life events, as graph facts",
        "eventSubgraph": "Your calendar events",
        "appSubgraph": "Your installed apps",
        "Software": "Installed apps, published for other parts of the system",
        "AppsRecentlyFocused": "Apps you used recently, for Games",
        "languageView": "The languages you use",
        "entitySummary": "A summary of each thing in your graph",
        "entitySubgraph": "Every entity in your graph",
        "hasAssociationSubgraph": "Which things are linked to which",
        "donationSubgraph": "Facts donated by apps",
        "sourceConfidence": "How much each data source is trusted",
        "inferenceFeaturesECR": "Inputs for working out who you mean",
        "initializeGlobalKnowledgeAssets": "Loads Apple's built-in world knowledge",
    ]

    static let contexts: [(String, String)] = [
        ("SpecificGeoHash", "precise location"), ("CoarseGeoHash", "rough location"), ("CoarseTimeOfDay", "time of day"),
        ("DayOfWeek", "day of week"), ("WiFi", "Wi-Fi network"), ("LOI", "regular place"), ("NonContextual", "overall habits"),
    ]

    static func matches(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    static func describe(_ name: String) -> String {
        if let known = descriptions[name] { return known }
        if let m = matches(#"^(person|loi)EntityRelevance(.+)Features$"#, name) {
            let subject = m[1] == "person" ? "Who you contact" : "Where you go"
            let found = contexts.filter { m[2].contains($0.0) }.map(\.1)
            return found.isEmpty ? subject : subject + ", by " + found.joined(separator: " and ")
        }
        if name.hasPrefix("SP") { return "An index of what happened after you used Siri" }
        if name.hasPrefix("ITD") { return "An index of Apple Intelligence session transcripts" }
        if name.hasPrefix("IT") { return "An index of Apple Intelligence telemetry" }
        // camelCase to plain words
        var words = ""
        for (i, ch) in name.enumerated() {
            if ch.isUppercase, i > 0, let prev = words.last, prev.isLowercase { words.append(" ") }
            words.append(ch)
        }
        return words.prefix(1).uppercased() + words.dropFirst().lowercased()
    }

    static func category(_ name: String) -> Int {
        for (i, c) in categories.enumerated() where matches(c.1, name) != nil { return i }
        return categories.count
    }

    static func load() -> WatchData? {
        guard let db = Database(GraphReader.platform + "/views.db") else { return nil }
        struct Entry { var name: String; var target: String; var listens: [WatchView.Listener] = []; var last = 0.0; var rows: Int? }
        var views: [Int: Entry] = [:]
        // Each view records where it keeps its results, so how much it holds can be counted directly.
        var stores: [String: Database] = [:]
        db.each("SELECT id, name, target, artifactPath, artifactTable FROM viewConfigRecord") { r in
            guard let id = r[0].int, let name = r[1].string else { return }
            var entry = Entry(name: name, target: r[2].string ?? "")
            if let path = r[3].string, let table = r[4].string, !path.isEmpty, !table.isEmpty,
               table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                for base in [GraphReader.platform + "/Artifacts/", GraphReader.platform + "/"] where entry.rows == nil {
                    let full = base + path
                    if stores[full] == nil, let opened = Database(full) { stores[full] = opened }
                    // Many views share one table and mark their own rows by name; count only those.
                    entry.rows = stores[full]?.rows("SELECT count(*) FROM \"\(table)\" WHERE viewName = ?", [name]).first?.first?.int
                        ?? stores[full]?.rows("SELECT count(*) FROM \"\(table)\"").first?.first?.int
                }
            }
            views[id] = entry
        }
        guard !views.isEmpty else { return nil }
        let ordered = views.keys.sorted()
        var lastRun: [Int: Double] = [:]
        db.each("SELECT sourceListenerConfigId, max(sourceUpdatedTimestamp) FROM sourceListenerState GROUP BY 1") { r in
            if let id = r[0].int { lastRun[id] = r[1].double ?? 0 }
        }
        db.each("SELECT sourceListenerConfigId, viewOrderedId, sourceType, schedule, config FROM sourceListenerConfig") { r in
            guard let listener = r[0].int, let position = r[1].int else { return }
            // viewOrderedId is a zero-based position; map it onto record ids.
            let id = views[position] != nil ? position : (position >= 0 && position < ordered.count ? ordered[position] : -1)
            guard views[id] != nil else { return }
            let type = r[2].string ?? ""
            let config = (r[4].string?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var ref = (config["stream"] as? String) ?? (config["name"] as? String) ?? (config["assetName"] as? String) ?? ""
            if type == "knowledgeGraph" { ref = "the graph: " + ((config["stores"] as? [String]) ?? []).joined(separator: ", ") }
            let schedule = r[3].string.flatMap { $0.isEmpty ? nil : $0 } ?? (config["schedule"] as? String) ?? ""
            views[id]!.listens.append(.init(type: type, ref: ref, schedule: schedule))
            views[id]!.last = max(views[id]!.last, lastRun[listener] ?? 0)
        }
        var out = views.values.map { v in
            WatchView(name: v.name, cat: category(v.name), what: describe(v.name), target: v.target, listens: v.listens,
                      last: v.last > 0 ? Int((v.last + GraphReader.appleEpoch).rounded()) : 0, rows: v.rows)
        }
        out.sort { a, b in
            if a.cat != b.cat { return a.cat < b.cat }
            if a.listens.count != b.listens.count { return a.listens.count > b.listens.count }
            return a.name < b.name
        }
        return WatchData(captured: Int(Date().timeIntervalSince1970), cats: categories.map(\.0) + ["Plumbing"], views: out)
    }
}
