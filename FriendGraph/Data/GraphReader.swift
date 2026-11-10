import Foundation

/// Reads what this Mac already holds about who the owner talks to, and turns it into a `Dataset`.
/// Read-only throughout, and nothing is sent anywhere.
///
/// Sources, all optional except that at least one message source must be readable:
///   - the Apple Intelligence interaction log (who and when, no text) and relationship scorecard
///   - Messages and WhatsApp, for history that reaches back further than the log
///   - Contacts and WhatsApp, for names and photos
enum GraphReader {
    static let home = NSHomeDirectory()
    static let platform = home + "/Library/IntelligencePlatform"
    static let whatsApp = home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
    static let messages = home + "/Library/Messages/chat.db"
    static let appleEpoch = 978_307_200.0

    enum Failure: Error { case noAccess, noConversations }

    /// True when the protected folders can be read, which needs Full Disk Access.
    static func hasAccess() -> Bool {
        Database(messages) != nil || Database(platform + "/Artifacts/siri/remembers/view.db") != nil
    }

    /// Counts names the way the log files them, remembering which came first so ties are stable.
    private struct Tally {
        var counts: [String: Int] = [:]
        var order: [String] = []
        mutating func add(_ name: String, _ n: Int = 1) {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += n
        }
        var top: String? {
            var best: String?, bestCount = 0
            for name in order where counts[name]! > bestCount { best = name; bestCount = counts[name]! }
            return best
        }
    }

    private static func addressBooks() -> [Database] {
        let base = home + "/Library/Application Support/AddressBook/Sources"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return folders.sorted().compactMap { Database(base + "/" + $0 + "/AddressBook-v22.abcddb") }
    }

    private static func jpeg(in blob: Data) -> Data? {
        guard let at = blob.range(of: Data([0xff, 0xd8, 0xff])) else { return nil }
        return blob.subdata(in: at.lowerBound..<blob.endIndex)
    }

    static func load(progress: @Sendable (String) -> Void = { _ in }) throws -> Dataset {
        guard hasAccess() else { throw Failure.noAccess }
        var notes: [String] = []

        // Local calendar parts for an Apple-epoch timestamp, without a Calendar call per message.
        let zone = TimeZone.current
        func localParts(_ t: Double) -> (day: Int, weekday: Int, hour: Int) {
            let unix = t + appleEpoch
            let shifted = unix + Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: unix)))
            let day = Int((shifted / 86400).rounded(.down))
            let secondOfDay = shifted - Double(day) * 86400
            return (day, ((day + 4) % 7 + 7) % 7 + 1, Int(secondOfDay / 3600))     // 1 January 1970 was a Thursday
        }

        // ---- Names from Contacts and WhatsApp, by handle
        progress("Reading names")
        var extra: [String: String] = [:]
        var cardPhotos: [String: Data] = [:]
        let books = addressBooks()
        let waContacts = Database(whatsApp + "/ContactsV2.sqlite")
        var waIDs: [String: String] = [:]           // WhatsApp's private id or number, before the @ -> phone number
        waContacts?.each("SELECT ZLID, ZWHATSAPPID, ZPHONENUMBER, ZFULLNAME FROM ZWAADDRESSBOOKCONTACT WHERE ZPHONENUMBER IS NOT NULL") { r in
            guard let raw = r[2].string else { return }
            let phone = Handle.phone(raw)
            for id in [r[0].string, r[1].string] {
                if let id, !id.isEmpty { waIDs[String(id.split(separator: "@")[0])] = phone }
            }
            if let full = r[3].string, !full.isEmpty, extra[Handle.key(phone)] == nil { extra[Handle.key(phone)] = full }
        }
        for book in books {
            for (table, column) in [("ZABCDPHONENUMBER", "ZFULLNUMBER"), ("ZABCDEMAILADDRESS", "ZADDRESS")] {
                book.each("SELECT r.ZFIRSTNAME, r.ZLASTNAME, t.\(column), r.ZTHUMBNAILIMAGEDATA FROM \(table) t JOIN ZABCDRECORD r ON r.Z_PK = t.ZOWNER WHERE t.\(column) IS NOT NULL") { r in
                    guard let value = r[2].string else { return }
                    let key = Handle.key(value.contains("@") ? value : Handle.phone(value))
                    // The photo on the card this number or address belongs to, whatever the card is called.
                    if cardPhotos[key] == nil, let blob = r[3].data, let image = jpeg(in: blob) { cardPhotos[key] = image }
                    let name = [r[0].string, r[1].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                    if !name.isEmpty, extra[key] == nil { extra[key] = name }
                }
            }
        }

        // ---- The interaction log: one-to-one messages and calls
        progress("Reading who you talk to")
        struct Message { var outgoing: Bool; var time: Double; var handle: String }
        struct Call { var time: Double; var seconds: Double; var handle: String }
        var messageLog: [Message] = [], callLog: [Call] = []
        var names: [String: Tally] = [:]
        var pretty: [String: String] = [:]          // "n:lower name" -> the name as written

        let log = Database(platform + "/Artifacts/siri/remembers/view.db")
        log?.each("""
            SELECT i.direction, i.startDate, e.id
            FROM interactions i
            JOIN interactionEntities ie ON ie.interactionRowid = i.rowid
            JOIN entities e ON e.rowid = ie.entityRowid
            WHERE i.domain = 'Messages' AND coalesce(json_extract(i.fields, '$.isGroup'), 0) = 0
              AND ((i.direction = 1 AND ie.parameter = 'senderHandle')
                OR (i.direction = 2 AND ie.parameter = 'recipientHandles'))
            ORDER BY i.startDate
            """) { r in
            guard let d = r[0].int, let t = r[1].double, let h = r[2].string else { return }
            messageLog.append(Message(outgoing: d == 2, time: t, handle: h))
        }
        log?.each("""
            SELECT i.startDate, i.durationSeconds, e.id
            FROM interactions i
            JOIN interactionEntities ie ON ie.interactionRowid = i.rowid
            JOIN entities e ON e.rowid = ie.entityRowid
            WHERE i.domain = 'Calls' AND e.type = 'PersonHandle'
            GROUP BY i.rowid, e.id ORDER BY i.startDate
            """) { r in
            guard let t = r[0].double, let h = r[2].string else { return }
            callLog.append(Call(time: t, seconds: r[1].double ?? 0, handle: h))
        }
        log?.each("SELECT id, fields FROM entities WHERE fields IS NOT NULL") { r in
            guard let h = r[0].string, !h.isEmpty, let json = r[1].string?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let name = object["name"] as? String, !name.isEmpty else { return }
            names[Handle.key(h), default: Tally()].add(name)
        }

        // Without the log (Apple Intelligence off, or an older macOS) fall back to the last year of
        // Messages, WhatsApp and call history, which carry the same who-and-when.
        let usingLog = !messageLog.isEmpty
        let chat = Database(messages)
        let waChats = Database(whatsApp + "/ChatStorage.sqlite")
        func waPhone(_ jid: String) -> String? {
            let id = String(jid.split(separator: "@")[0])
            return jid.hasSuffix("@lid") ? waIDs[id] : "+" + id
        }
        let chatSQL = """
            SELECT m.date, h.id, m.is_from_me FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id AND c.style = 45
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            """
        let waSQL = """
            SELECT m.ZMESSAGEDATE, s.ZCONTACTJID, m.ZISFROMME FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION WHERE s.ZSESSIONTYPE = 0
            """
        /// Messages stores nanoseconds since 2001 (seconds on very old rows).
        func chatTime(_ raw: Double) -> Double { raw > 1e12 ? raw / 1e9 : raw }

        if !usingLog {
            notes.append("The Apple Intelligence log was not found, so closeness uses the last year of Messages and WhatsApp.")
            for (key, name) in extra { names[key, default: Tally()].add(name) }
            let cutoff = Date().timeIntervalSince1970 - appleEpoch - 365 * 86400
            chat?.each(chatSQL) { r in
                guard let raw = r[0].double, let h = r[1].string else { return }
                let t = chatTime(raw)
                if t >= cutoff { messageLog.append(Message(outgoing: (r[2].int ?? 0) != 0, time: t, handle: h)) }
            }
            waChats?.each(waSQL) { r in
                guard let t = r[0].double, t >= cutoff, let jid = r[1].string, let phone = waPhone(jid) else { return }
                messageLog.append(Message(outgoing: (r[2].int ?? 0) != 0, time: t, handle: phone))
            }
            messageLog.sort { $0.time < $1.time }
            Database(home + "/Library/Application Support/CallHistoryDB/CallHistory.storedata")?
                .each("SELECT ZDATE, ZDURATION, ZADDRESS FROM ZCALLRECORD WHERE ZADDRESS IS NOT NULL") { r in
                    let address = r[2].string ?? r[2].data.map { String(decoding: $0, as: UTF8.self) }
                    guard let t = r[0].double, t >= cutoff, let address, !address.isEmpty else { return }
                    callLog.append(Call(time: t, seconds: r[1].double ?? 0, handle: address))
                }
        }
        guard !messageLog.isEmpty else { throw Failure.noConversations }

        func person(_ h: String) -> String {
            if let best = names[Handle.key(h)]?.top, !best.hasPrefix("~") {
                let key = "n:" + Handle.normalisedName(best)
                return key
            }
            return Handle.key(h)
        }
        for tally in names.values {
            for name in tally.order where !name.hasPrefix("~") {
                let key = "n:" + Handle.normalisedName(name)
                if pretty[key] == nil { pretty[key] = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            }
        }
        for name in extra.values {
            let key = "n:" + Handle.normalisedName(name)
            if pretty[key] == nil { pretty[key] = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        }

        // ---- The owner's own numbers and addresses, so notes-to-self never show up as a friend
        var own = Set<String>(), ownNames = Set<String>(), ownerIDs: [String] = []
        let graph = Database(platform + "/graph.db")
        let internalViews = Database(platform + "/Artifacts/internal/views.db")
        graph?.each("SELECT CAST(subject AS TEXT) FROM stable_graph WHERE predicate = 'nm_isCurrentUser'") { r in
            if let s = r[0].string { ownerIDs.append(s) }
        }
        for id in ownerIDs {
            graph?.each("SELECT object FROM stable_graph WHERE CAST(subject AS TEXT) = ? AND predicate = 'PS520' AND relationshipPredicate IN ('PS407', 'PS406')", [id]) { r in
                if let v = r[0].string { own.insert(Handle.key(v)) }
            }
            graph?.each("SELECT object FROM stable_graph WHERE CAST(subject AS TEXT) = ? AND predicate = 'PS33'", [id]) { r in
                if let v = r[0].string { ownNames.insert(Handle.normalisedName(v)) }
            }
            internalViews?.each("SELECT handle FROM handle_id WHERE CAST(id AS TEXT) = ?", [id]) { r in
                if let v = r[0].string { own.insert(Handle.key(v)) }
            }
        }
        for sql in ["SELECT DISTINCT destination_caller_id FROM message WHERE coalesce(destination_caller_id, '') <> ''",
                    "SELECT DISTINCT last_addressed_handle FROM chat WHERE coalesce(last_addressed_handle, '') <> ''",
                    "SELECT DISTINCT account_login FROM chat WHERE coalesce(account_login, '') <> ''"] {
            chat?.each(sql) { r in
                guard let v = r[0].string else { return }
                let value = v.split(separator: ":", maxSplits: 1).last.map(String.init) ?? v
                own.insert(Handle.key(value))
            }
        }
        func isMe(_ h: String) -> Bool {
            if own.contains(Handle.key(h)) { return true }
            let p = person(h)
            return p.hasPrefix("n:") && ownNames.contains(String(p.dropFirst(2)))
        }

        // ---- One record per person
        var people: [String: Scoring.Raw] = [:], order: [String] = []
        func touch(_ key: String) { if people[key] == nil { people[key] = Scoring.Raw(); order.append(key) } }
        for m in messageLog where !isMe(m.handle) {
            let key = person(m.handle); touch(key)
            people[key]!.events.append(Scoring.Event(time: m.time, outgoing: m.outgoing))
            people[key]!.handles.insert(m.handle)
        }
        for c in callLog where !isMe(c.handle) {
            let key = person(c.handle); touch(key)
            people[key]!.handles.insert(c.handle)
            if c.seconds > 0 { people[key]!.calls += 1; people[key]!.callMinutes += c.seconds / 60 }
        }

        // ---- What Apple itself has worked out: Family Sharing, and the relationship scorecard
        progress("Working out who is close")
        var idsFor: [String: Set<String>] = [:]
        internalViews?.each("SELECT handle, CAST(id AS TEXT) FROM handle_id") { r in
            if let h = r[0].string, let id = r[1].string { idsFor[person(h), default: []].insert(id) }
        }
        var familyIDs = Set<String>()
        Database(platform + "/Artifacts/entityRelevance/entityImportanceSignals.db")?
            .each("SELECT CAST(entityIdentifier AS TEXT) FROM entityImportanceSignalsIDMap WHERE isICloudFamily") { r in
                if let id = r[0].string { familyIDs.insert(id) }
            }
        let familyKeys = Set(order.filter { !(idsFor[$0] ?? []).isDisjoint(with: familyIDs) })

        let tagColumns = ["mother", "father", "parent", "sister", "brother", "sibling", "family", "friend", "partner", "coworker", "child", "son", "daughter"]
        var tags: [String: [Double]] = [:]
        Database(platform + "/Artifacts/entityTagging/entityTagging.db")?
            .each("SELECT CAST(mdid AS TEXT), \(tagColumns.joined(separator: ", ")) FROM entity_tagging") { r in
                if let id = r[0].string { tags[id] = r.dropFirst().map { $0.double ?? 0 } }
            }
        func guess(_ key: String, family: Bool) -> Relationship {
            var best = [Double](repeating: 0, count: tagColumns.count)
            for id in idsFor[key] ?? [] {
                if let t = tags[id] { for i in best.indices { best[i] = max(best[i], t[i]) } }
            }
            func top(_ cols: String...) -> Double { cols.map { best[tagColumns.firstIndex(of: $0)!] }.max() ?? 0 }
            // Apple scores specific family roles confidently when it knows them; "partner" it does not,
            // so that guess is made afterwards from Family Sharing.
            let specific: [(Relationship, Double)] = [
                (.parent, top("mother", "father", "parent")), (.child, top("child", "son", "daughter")),
                (.sibling, top("sister", "brother", "sibling")), (.partner, top("partner")),
            ]
            if let strongest = specific.max(by: { $0.1 < $1.1 }), strongest.1 >= 0.5 { return strongest.0 }
            if family || top("family") >= 0.85 { return .family }
            if top("coworker") >= 0.5 && top("coworker") > top("friend") { return .colleague }
            return .friend
        }

        let rows = Scoring.score(people: people, order: order, family: familyKeys, local: localParts)
        guard !rows.isEmpty else { throw Failure.noConversations }

        // ---- Day-by-day history, as far back as Messages and WhatsApp go
        progress("Reading your history")
        func whoIs(_ h: String) -> String {
            let p = person(h)
            if p.hasPrefix("n:") { return p }
            if let name = extra[Handle.key(h)] { return "n:" + Handle.normalisedName(name) }
            return p
        }
        var history: [String: [Int: (incoming: Int, outgoing: Int)]] = [:]
        func take(_ time: Double, _ handle: String, _ mine: Bool) {
            guard time > 0, !handle.isEmpty, !isMe(handle) else { return }
            let day = localParts(time).day
            var entry = history[whoIs(handle), default: [:]][day] ?? (0, 0)
            if mine { entry.outgoing += 1 } else { entry.incoming += 1 }
            history[whoIs(handle), default: [:]][day] = entry
        }
        chat?.each(chatSQL) { r in
            if let raw = r[0].double, let h = r[1].string { take(chatTime(raw), h, (r[2].int ?? 0) != 0) }
        }
        waChats?.each(waSQL) { r in
            if let t = r[0].double, let jid = r[1].string, let phone = waPhone(jid) { take(t, phone, (r[2].int ?? 0) != 0) }
        }
        if chat == nil { notes.append("Messages history could not be read.") }

        func historyKey(_ row: Scoring.Row) -> String {
            row.key.hasPrefix("n:") ? row.key : whoIs(row.handles.sorted().first ?? row.key)
        }
        let scoredKeys = rows.map(historyKey)
        // If the long history is missing someone (or missing entirely), fall back to the log itself.
        for (row, key) in zip(rows, scoredKeys) where history[key] == nil {
            for e in people[row.key]?.events ?? [] {
                let day = localParts(e.time).day
                var entry = history[key, default: [:]][day] ?? (0, 0)
                if e.outgoing { entry.outgoing += 1 } else { entry.incoming += 1 }
                history[key, default: [:]][day] = entry
            }
        }
        let allDays = history.values.flatMap { $0.keys }
        let lo = allDays.min() ?? 0, hi = allDays.max() ?? 0

        // Anyone among the four most-messaged two-way contacts in any quarter joins the moving timeline.
        var picked: [String: Int] = [:], pickedOrder: [String] = []
        var quarter = lo
        while quarter <= hi {
            var tally: [(Int, String)] = []
            for (key, days) in history {
                var i = 0, o = 0
                for (day, v) in days where day >= quarter && day < quarter + 91 { i += v.incoming; o += v.outgoing }
                if i >= 3 && o >= 3 { tally.append((i + o, key)) }
            }
            for (n, key) in tally.sorted(by: { $0.0 == $1.0 ? $0.1 > $1.1 : $0.0 > $1.0 }).prefix(4) {
                if picked[key] == nil { pickedOrder.append(key) }
                picked[key, default: 0] += n
            }
            quarter += 91
        }
        let scoredSet = Set(scoredKeys)
        let earlierKeys = pickedOrder
            .filter { !scoredSet.contains($0) && $0.hasPrefix("n:") }     // a nameless number from years ago means nothing on screen
            .sorted { picked[$0]! > picked[$1]! }
            .prefix(14)
            .sorted { (history[$0]?.keys.min() ?? lo) < (history[$1]?.keys.min() ?? lo) }

        func series(_ key: String) -> [UInt16] {
            var out = [UInt16](repeating: 0, count: hi - lo + 1)
            for (day, v) in history[key] ?? [:] { out[day - lo] = UInt16(clamping: v.incoming + v.outgoing) }
            return out
        }

        // ---- Photos: the Contacts picture, or failing that their WhatsApp profile picture
        progress("Finding photos")
        var waPictures: [String: [String]] = [:]
        waChats?.each("SELECT ZJID, ZPATH FROM ZWAPROFILEPICTUREITEM WHERE ZPATH IS NOT NULL AND (ZJID LIKE '%@lid' OR ZJID LIKE '%@s.whatsapp.net')") { r in
            guard let jid = r[0].string, let path = r[1].string else { return }
            let id = String(jid.split(separator: "@")[0])
            let phone = waIDs[id] ?? (jid.hasSuffix("@s.whatsapp.net") ? "+" + id : nil)
            if let phone { waPictures[whoIs(phone), default: []].append(path) }
        }
        func photo(name: String, key: String, handles: Set<String> = []) -> Data? {
            for handle in handles.sorted() { if let image = cardPhotos[Handle.key(handle)] { return image } }
            let parts = name.replacingOccurrences(of: "~", with: "").split(separator: " ").map { $0.lowercased() }
            if parts.count >= 2 {
                for book in books {
                    let found = book.rows("SELECT ZTHUMBNAILIMAGEDATA FROM ZABCDRECORD WHERE ZTHUMBNAILIMAGEDATA IS NOT NULL AND lower(ZFIRSTNAME) = ? AND lower(ZLASTNAME) = ? LIMIT 1",
                                          [parts.first!, parts.last!])
                    if let blob = found.first?.first?.data, let image = jpeg(in: blob) { return image }
                }
            }
            for path in waPictures[key] ?? [] {
                let full = whatsApp + "/" + path
                let folder = (full as NSString).deletingLastPathComponent, prefix = (full as NSString).lastPathComponent
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(prefix) }
                var best: (Int, String)?
                for file in files {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: folder + "/" + file))?[.size] as? Int) ?? 0
                    if size > 2000, size > (best?.0 ?? 0) { best = (size, folder + "/" + file) }
                }
                if let best, let data = FileManager.default.contents(atPath: best.1), data.starts(with: [0xff, 0xd8, 0xff]) { return data }
            }
            return nil
        }

        var scored: [Person] = []
        for (row, key) in zip(rows, scoredKeys) {
            var tally = Tally()
            for h in row.handles.sorted() {
                if let t = names[Handle.key(h)] { for name in t.order { tally.add(name, t.counts[name]!) } }
            }
            let name = tally.top.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
                ?? pretty[key] ?? row.handles.sorted().first ?? "Unknown"
            var p = Person(id: key, name: name)
            p.photo = photo(name: name, key: key, handles: row.handles)
            p.familySharing = row.family
            p.guess = guess(row.key, family: row.family)
            p.score = row.score
            p.messages = row.count; p.incoming = row.incoming; p.outgoing = row.outgoing
            p.myReplyMinutes = row.myReplyMinutes; p.theirReplyMinutes = row.theirReplyMinutes
            p.calls = row.calls; p.callMinutes = row.callMinutes
            p.daily = series(key)
            scored.append(p)
        }
        // The closest Family Sharing member who is not a parent, child or sibling is most likely a partner.
        if !scored.contains(where: { $0.guess == .partner }),
           let likely = scored.firstIndex(where: { $0.familySharing && $0.guess == .family }) {
            scored[likely].guess = .partner
        }
        var earlier: [Person] = []
        for key in earlierKeys {
            let name = pretty[key] ?? String(key.dropFirst(2)).capitalized
            var p = Person(id: key, name: name)
            p.photo = photo(name: name, key: key)
            p.daily = series(key)
            p.messages = p.daily.reduce(0) { $0 + Int($1) }
            earlier.append(p)
        }

        var used = Set<String>(ownerIDs)
        for row in rows { used.formUnion(idsFor[row.key] ?? []) }
        let others = tags.keys.filter { !used.contains($0) }.count

        progress("Looking at what your Mac keeps track of")
        let firstDay = Date(timeIntervalSince1970: Double(lo) * 86400 - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(lo) * 86400))))
        return Dataset(scored: scored, earlier: earlier, othersKnown: max(others, people.count - rows.count),
                       firstDay: firstDay, days: hi - lo + 1, watch: WatchReader.load(), isSample: false, notes: notes)
    }
}
