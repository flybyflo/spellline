import Foundation
import OSLog
import SQLite3

// MARK: - Matcher

protocol PromptMatching: Sendable {
    func match(text: String) -> [MatchCandidate]
}

struct HeuristicPromptMatcher: PromptMatching {
    init() {}

    func match(text: String) -> [MatchCandidate] {
        var results: [MatchCandidate] = []
        let nsText = text as NSString

        for entity in ["ogre", "goblin", "train", "boss"] {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: entity))\\b"
            for range in ranges(for: pattern, in: text) {
                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: range,
                        semanticKey: "tag:\(entity)",
                        kind: .tag,
                        value: .tag(entity),
                        confidence: 1,
                        displayStyle: .chip,
                        matchedText: nsText.substring(with: range),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        for range in ranges(for: "\\b(bigger|smaller)\\b", in: text) {
            let raw = nsText.substring(with: range).lowercased()
            let value = raw == "bigger" ? SizePreset.bigger : SizePreset.smaller
            results.append(
                MatchCandidate(
                    id: UUID(),
                    range: range,
                    semanticKey: "size",
                    kind: .size,
                    value: .size(value),
                    confidence: 1,
                    displayStyle: .menu,
                    matchedText: nsText.substring(with: range),
                    commitsOnDelimiter: false
                )
            )
        }

        if let regex = try? NSRegularExpression(pattern: "\\bspawn\\s+(\\d+)\\b", options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let valueRange = match.range(at: 1)
                let count = Int(nsText.substring(with: valueRange)) ?? 1
                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: valueRange,
                        semanticKey: "count",
                        kind: .count,
                        value: .int(count),
                        confidence: 1,
                        displayStyle: .stepper,
                        matchedText: nsText.substring(with: valueRange),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "\\brotate\\s+((\\d+)(?:°|\\s*degrees?))(?:\\s+every\\s+((\\d+)\\s*(?:s|sec|secs|seconds?)))?",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let fullAngleRange = match.range(at: 1)
                let angleValueRange = match.range(at: 2)
                let degrees = Double(nsText.substring(with: angleValueRange)) ?? 0

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: fullAngleRange,
                        semanticKey: "numberWithUnit",
                        kind: .numberWithUnit,
                        value: .angle(degrees),
                        confidence: 1,
                        displayStyle: .stepper,
                        matchedText: nsText.substring(with: fullAngleRange),
                        commitsOnDelimiter: false
                    )
                )

                let fullTimerRange = match.range(at: 3)
                let timerValueRange = match.range(at: 4)
                if fullTimerRange.location != NSNotFound, timerValueRange.location != NSNotFound {
                    let seconds = Int(nsText.substring(with: timerValueRange)) ?? 10
                    results.append(
                        MatchCandidate(
                            id: UUID(),
                            range: fullTimerRange,
                            semanticKey: "timer",
                            kind: .timer,
                            value: .seconds(seconds),
                            confidence: 1,
                            displayStyle: .stepper,
                            matchedText: nsText.substring(with: fullTimerRange),
                            commitsOnDelimiter: false
                        )
                    )
                }
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(\\d+)\\s*(s|sec|secs|seconds?)(?=$|[^A-Za-z0-9])",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let fullRange = match.range(at: 0)
                let valueRange = match.range(at: 1)
                let seconds = Int(nsText.substring(with: valueRange)) ?? 10

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: fullRange,
                        semanticKey: "timer",
                        kind: .timer,
                        value: .seconds(seconds),
                        confidence: 0.95,
                        displayStyle: .stepper,
                        matchedText: nsText.substring(with: fullRange),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        for preset in FilterPreset.allCases {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: preset.rawValue))\\b"
            for range in ranges(for: pattern, in: text) {
                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: range,
                        semanticKey: "preset:\(preset.rawValue.lowercased())",
                        kind: .preset,
                        value: .preset(preset),
                        confidence: 1,
                        displayStyle: .menu,
                        matchedText: nsText.substring(with: range),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "\\b([1-9]|1[0-2]):([0-5][0-9])\\s*(AM|PM)\\b",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let hourRange = match.range(at: 1)
                let minuteRange = match.range(at: 2)
                let ampmRange = match.range(at: 3)
                let h = Int(nsText.substring(with: hourRange)) ?? 12
                let mins = Int(nsText.substring(with: minuteRange)) ?? 0
                let ampm = nsText.substring(with: ampmRange).uppercased()
                let isPM = ampm == "PM"

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: match.range,
                        semanticKey: "clock:\(h):\(mins):\(isPM)",
                        kind: .clock,
                        value: .timeOfDay(hour12: h, minute: mins, isPM: isPM),
                        confidence: 1,
                        displayStyle: .wheel,
                        matchedText: nsText.substring(with: match.range),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "\\b(from|to)\\s+([^,.;\\n]+?)(?=\\s+\\b(?:from|to|and|then|with)\\b|\\s*(?:->|→)|[,.;\\n]|$)",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let roleRange = match.range(at: 1)
                let queryRange = match.range(at: 2)
                guard roleRange.location != NSNotFound, queryRange.location != NSNotFound else { continue }

                let roleRaw = nsText.substring(with: roleRange).lowercased()
                guard let role = StationRole(rawValue: roleRaw) else { continue }

                let capturedQuery = nsText.substring(with: queryRange)
                // Leading trim only: trailing spaces must stay in-range or they render as plain text after the badge.
                let rawQuery = capturedQuery.trimmingLeadingWhitespaceForStationQuery
                guard rawQuery.count >= 1 else { continue }

                guard let stationMatch = bestStationMatch(for: rawQuery, role: role) else { continue }
                let best = stationMatch.name

                // Use the full regex capture for the token range. `consumedQuery` is normalized (no trailing
                // space) for lookup; mapping it back with `range(of:)` would shorten the range and drop
                // trailing spaces the user typed inside the station field.
                var stationRange = queryRange
                let capturedFull = nsText.substring(with: stationRange)
                if let truncated = stationQueryRangeTruncatedIfUniqueMatchCompleted(
                    queryRange: stationRange,
                    canonicalName: best,
                    captured: capturedFull,
                    optionCount: stationMatch.optionCount
                ) {
                    stationRange = truncated
                }
                let stationMatchedText = nsText.substring(with: stationRange)
                let confidence: Double = best.caseInsensitiveCompare(stationMatch.consumedQuery) == .orderedSame ? 1 : 0.98

                let autoAccept =
                    shouldAutoAcceptStation(in: text, queryRange: stationRange, capturedQuery: stationMatchedText)

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: stationRange,
                        semanticKey: "station:\(role.rawValue):\(best.lowercased())",
                        kind: .station,
                        value: .station(role: role, name: best),
                        confidence: confidence,
                        displayStyle: .menu,
                        matchedText: stationMatchedText,
                        commitsOnDelimiter: !autoAccept
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "\\bbackground tint\\s+(0(?:\\.\\d+)?|1(?:\\.0+)?)",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let valueRange = match.range(at: 1)
                let amount = Double(nsText.substring(with: valueRange)) ?? 0.5
                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: valueRange,
                        semanticKey: "background:tint",
                        kind: .background,
                        value: .percentage(amount),
                        confidence: 1,
                        displayStyle: .slider,
                        matchedText: nsText.substring(with: valueRange),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "(?<![\\d.])(0(?:\\.\\d+)?|1(?:\\.0+)?)(?=$|[^\\w%])",
            options: []
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let fullRange = match.range(at: 0)
                let amount = Double(nsText.substring(with: fullRange)) ?? 0
                let normalized = min(1, max(0, amount))
                let normalizedKey = Int(round(normalized * 100))

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: fullRange,
                        semanticKey: "fraction:\(normalizedKey)",
                        kind: .background,
                        value: .percentage(normalized),
                        confidence: 0.9,
                        displayStyle: .slider,
                        matchedText: nsText.substring(with: fullRange),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "\\b([a-z]+(?:\\s+[a-z]+)*\\s+warning)\\b",
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let warningRange = match.range(at: 1)
                let message = nsText.substring(with: warningRange).capitalized
                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: warningRange,
                        semanticKey: "status:\(message.lowercased())",
                        kind: .status,
                        value: .status(message),
                        confidence: 1,
                        displayStyle: .badge,
                        matchedText: nsText.substring(with: warningRange),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: "(?<![\\d.])((?:100)|(?:\\d{1,2}))\\s*%(?=$|[^\\w])",
            options: []
        ) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let valueRange = match.range(at: 1)
                let pct = Double(nsText.substring(with: valueRange)) ?? 0
                let amount = min(1, max(0, pct / 100))
                let pctInt = Int(round(amount * 100))

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: match.range,
                        semanticKey: "percent:\(pctInt)",
                        kind: .background,
                        value: .percentage(amount),
                        confidence: 0.95,
                        displayStyle: .slider,
                        matchedText: nsText.substring(with: match.range),
                        commitsOnDelimiter: false
                    )
                )
            }
        }

        return results
    }

    private func ranges(for pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range)
    }

    private func shouldAutoAcceptStation(in text: String, queryRange: NSRange, capturedQuery: String) -> Bool {
        // Keep station as live-completion while typing and only commit on hard delimiters.
        // Trailing spaces should not auto-commit, so users can continue typing multi-word names.
        let nsText = text as NSString
        let end = queryRange.location + queryRange.length
        guard end < nsText.length else { return false }

        // If the next role starts (`to`/`from`), commit current station.
        let remainder = nsText.substring(from: end)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if remainder.hasPrefix("to ") || remainder == "to" ||
            remainder.hasPrefix("from ") || remainder == "from" {
            return true
        }

        let next = nsText.substring(with: NSRange(location: end, length: 1))
        guard let scalar = next.unicodeScalars.first else { return false }
        return CharacterSet.punctuationCharacters.union(.newlines).contains(scalar)
    }

    private func bestStationMatch(for rawQuery: String, role: StationRole) -> (name: String, consumedQuery: String, optionCount: Int)? {
        let normalizedQuery = rawQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
        guard !normalizedQuery.isEmpty else { return nil }

        let words = normalizedQuery.split(separator: " ").map(String.init)
        var candidates: [String] = []

        for count in stride(from: words.count, through: 1, by: -1) {
            let base = words.prefix(count).joined(separator: " ")
            appendStationCandidate(base, to: &candidates)
            if !base.isEmpty {
                appendStationCandidate(String(base.dropLast(1)), to: &candidates)
                if base.count >= 2 {
                    appendStationCandidate(String(base.dropLast(2)), to: &candidates)
                }
            }
        }

        var seen: Set<String> = []
        var fuzzyFallback: (name: String, consumedQuery: String, optionCount: Int)?

        for candidate in candidates where seen.insert(candidate).inserted {
            let options = StationSearchIndex.shared.matches(for: candidate, role: role, limit: 8)
            guard let best = options.first else { continue }

            if isStrongStationPrefixMatch(query: candidate, stationName: best) {
                return (best, candidate, options.count)
            }

            if fuzzyFallback == nil {
                fuzzyFallback = (best, candidate, options.count)
            }
        }

        return fuzzyFallback
    }

    private func appendStationCandidate(_ raw: String, to list: inout [String]) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !list.contains(value) {
            list.append(value)
        }
    }

    private func isStrongStationPrefixMatch(query: String, stationName: String) -> Bool {
        let normalizedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let normalizedStation = stationName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return normalizedStation.hasPrefix(normalizedQuery)
    }

    /// When a unique station match is complete and the regex capture still extends past the canonical name
    /// (e.g. user typed another letter with no delimiter), shrink the candidate range so following text stays plain.
    private func stationQueryRangeTruncatedIfUniqueMatchCompleted(
        queryRange: NSRange,
        canonicalName: String,
        captured: String,
        optionCount: Int
    ) -> NSRange? {
        guard optionCount == 1 else { return nil }
        let foldedBest = canonicalName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let foldedCaptured = captured.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !foldedBest.isEmpty,
              foldedCaptured.hasPrefix(foldedBest),
              foldedCaptured.count > foldedBest.count else { return nil }

        let endIndex = stationOriginalIndex(afterFoldedPrefixLength: foldedBest.count, in: captured)
        let prefixStr = String(captured[..<endIndex])
        let newLength = (prefixStr as NSString).length
        guard newLength > 0, newLength < queryRange.length else { return nil }
        return NSRange(location: queryRange.location, length: newLength)
    }

    /// Aligned with `InlineStationTokenView.originalIndex` — maps folded-prefix length to `String.Index` in `s`.
    private func stationOriginalIndex(afterFoldedPrefixLength n: Int, in s: String) -> String.Index {
        guard n > 0 else { return s.startIndex }
        let fullFolded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard n <= fullFolded.count else { return s.endIndex }
        let targetPrefix = String(fullFolded.prefix(n))
        var end = s.startIndex
        while end < s.endIndex {
            let next = s.index(after: end)
            let sub = String(s[..<next])
            let subFolded = sub.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if subFolded.count >= n, String(subFolded.prefix(n)) == targetPrefix {
                return next
            }
            end = next
        }
        return s.endIndex
    }

}

private extension String {
    /// Leading whitespace only (unlike `trimmingCharacters(in: .whitespacesAndNewlines)`), so trailing spaces
    /// typed inside the station query stay part of the regex capture and the badge range.
    var trimmingLeadingWhitespaceForStationQuery: String {
        guard let i = firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[i...])
    }
}

struct StationSearchIndex {
    static let shared = StationSearchIndex()
    private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "StationSearch")
    private static let aliases: [String: String] = [
        "hbf": "hauptbahnhof",
        "bhf": "bahnhof"
    ]

    private typealias Entry = (original: String, folded: String, expanded: String)

    private let allEntries: [Entry]
    private let fromRankedEntries: [Entry]
    private let toRankedEntries: [Entry]
    private let cache = NSCache<NSString, NSArray>()

    private init() {
        let names = Self.loadStationNames()
        let entries: [Entry] = names.map { name in
            let folded = Self.fold(name)
            let expanded = Self.expandAbbreviations(in: folded)
            return (original: name, folded: folded, expanded: expanded)
        }

        allEntries = entries
        fromRankedEntries = Self.preferredRanking(entries: entries, hint: "wien")
        toRankedEntries = Self.preferredRanking(entries: entries, hint: "salzburg")

        cache.countLimit = 512

        Self.logger.info("Loaded station index with \(entries.count, privacy: .public) names")
    }

    func matches(for query: String, role: StationRole? = nil, limit: Int) -> [String] {
        let q = Self.expandAbbreviations(in: Self.fold(query))
        guard !q.isEmpty else { return [] }

        let cacheKey = NSString(string: "\(role?.rawValue ?? "-")|\(q)|\(limit)")
        if let cached = cache.object(forKey: cacheKey) {
            return cached.compactMap { $0 as? String }
        }

        let ranked = rankedEntries(for: role)

        var prefix: [String] = []
        var contains: [String] = []
        var fuzzy: [(name: String, score: Int)] = []

        for entry in ranked {
            let value = entry.expanded

            if value.hasPrefix(q) {
                prefix.append(entry.original)
                continue
            }

            if value.contains(q) {
                contains.append(entry.original)
                continue
            }

            let score = Self.fuzzyScore(query: q, candidate: value)
            if score > 0 {
                fuzzy.append((entry.original, score))
            }
        }

        fuzzy.sort {
            if $0.score == $1.score {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.score > $1.score
        }

        let result = Array((prefix + contains + fuzzy.map(\.name)).prefix(limit))
        cache.setObject(result as NSArray, forKey: cacheKey)

        Self.logger.debug("Station match query='\(query, privacy: .public)' role='\(role?.rawValue ?? "-", privacy: .public)' count=\(result.count, privacy: .public)")
        return result
    }

    private func rankedEntries(for role: StationRole?) -> [Entry] {
        switch role {
        case .from:
            return fromRankedEntries
        case .to:
            return toRankedEntries
        case nil:
            return allEntries
        }
    }

    private static func preferredRanking(entries: [Entry], hint: String) -> [Entry] {
        let preferred = entries.filter { $0.folded.contains(hint) }
        let rest = entries.filter { !$0.folded.contains(hint) }
        return preferred + rest
    }

    private static func fuzzyScore(query: String, candidate: String) -> Int {
        var bestScore = 0

        if let typoScore = typoPrefixScore(query: query, candidate: candidate) {
            bestScore = max(bestScore, typoScore)
        }

        guard query.count >= 2 else { return bestScore }

        let queryScalars = Array(query)
        let candidateScalars = Array(candidate)

        var matched = 0
        var cIndex = 0
        var firstMatch: Int?
        var lastMatch: Int?

        for qChar in queryScalars {
            var found = false
            while cIndex < candidateScalars.count {
                if candidateScalars[cIndex] == qChar {
                    if firstMatch == nil { firstMatch = cIndex }
                    lastMatch = cIndex
                    matched += 1
                    cIndex += 1
                    found = true
                    break
                }
                cIndex += 1
            }
            if !found { return bestScore }
        }

        guard matched >= max(2, queryScalars.count / 2) else { return bestScore }
        let spread = (lastMatch ?? 0) - (firstMatch ?? 0)
        let compactBonus = max(0, 24 - spread)
        let coverage = Int((Double(matched) / Double(max(1, queryScalars.count))) * 100.0)
        return max(bestScore, coverage + compactBonus)
    }

    private static func typoPrefixScore(query: String, candidate: String) -> Int? {
        guard query.count >= 3 else { return nil }

        let q = Array(query)
        let candidatePrefix = Array(String(candidate.prefix(q.count)))
        guard !candidatePrefix.isEmpty else { return nil }

        let distance = levenshteinDistance(q, candidatePrefix)
        guard distance <= 2 else { return nil }

        return 68 - distance * 14 + min(q.count, 10)
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var prev = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    prev[j] + 1,        // deletion
                    current[j - 1] + 1, // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &current)
        }

        return prev[rhs.count]
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func expandAbbreviations(in value: String) -> String {
        value
            .split(separator: " ")
            .map { part in Self.aliases[String(part)] ?? String(part) }
            .joined(separator: " ")
    }

    private static func loadStationNames() -> [String] {
        guard let dbURL = stationDatabaseURL() else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            Self.logger.error("Failed to open station DB at \(dbURL.path, privacy: .public)")
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT DISTINCT ZSTOP_NAME
        FROM ZSTOP
        WHERE ZSTOP_NAME IS NOT NULL AND TRIM(ZSTOP_NAME) <> ''
        ORDER BY ZSTOP_NAME COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Self.logger.error("Failed to prepare station query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                names.append(String(cString: cString))
            }
        }
        return names
    }

    private static func stationDatabaseURL() -> URL? {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let copied = appSupport
                .appendingPathComponent("CoreDataStore", isDirectory: true)
                .appendingPathComponent("spellline.sqlite")
            if fm.fileExists(atPath: copied.path) {
                Self.logger.info("Using copied station DB at \(copied.path, privacy: .public)")
                return copied
            }
        }

        if let bundled = Bundle.main.url(forResource: "spellline", withExtension: "sqlite", subdirectory: "preloaded_store") {
            Self.logger.info("Using bundled station DB at \(bundled.path, privacy: .public)")
            return bundled
        }
        let fallback = Bundle.main.url(forResource: "spellline", withExtension: "sqlite")
        if let fallback {
            Self.logger.info("Using fallback station DB at \(fallback.path, privacy: .public)")
        } else {
            Self.logger.error("No station DB found in app support or bundle")
        }
        return fallback
    }
}

// MARK: - Match Resolution

enum MatchResolution {
    static func nonOverlappingGreedy(_ candidates: [MatchCandidate]) -> [MatchCandidate] {
        let sorted = candidates.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var accepted: [MatchCandidate] = []
        var cursor = 0

        for candidate in sorted where candidate.range.location >= cursor {
            let overlaps = accepted.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
            if overlaps {
                continue
            }
            accepted.append(candidate)
            cursor = candidate.range.upperBound
        }

        return accepted.sorted { $0.range.location < $1.range.location }
    }
}
