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
                let rawQuery = capturedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawQuery.count >= 1 else { continue }

                guard let stationMatch = bestStationMatch(for: rawQuery, role: role) else { continue }
                let best = stationMatch.name

                let nsCaptured = capturedQuery as NSString
                let localRange = nsCaptured.range(of: stationMatch.consumedQuery, options: [.anchored, .caseInsensitive])
                guard localRange.location != NSNotFound else { continue }
                let stationRange = NSRange(
                    location: queryRange.location + localRange.location,
                    length: localRange.length
                )
                let stationMatchedText = nsText.substring(with: stationRange)
                let confidence: Double = best.caseInsensitiveCompare(stationMatch.consumedQuery) == .orderedSame ? 1 : 0.98
                let autoAccept = stationMatch.optionCount == 1 ||
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
            candidates.append(words.prefix(count).joined(separator: " "))
        }
        // Character-prefix fallback keeps the station badge alive through transient typo states
        // while users are correcting input (e.g. "wiee" -> backspace -> "wien").
        let chars = Array(normalizedQuery)
        for charCount in stride(from: chars.count, through: 1, by: -1) {
            let candidate = String(chars.prefix(charCount))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                candidates.append(candidate)
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

    private func isStrongStationPrefixMatch(query: String, stationName: String) -> Bool {
        let normalizedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let normalizedStation = stationName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return normalizedStation.hasPrefix(normalizedQuery)
    }

}

struct StationSearchIndex {
    static let shared = StationSearchIndex()
    private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "StationSearch")
    private let normalized: [(original: String, folded: String)]
    private let aliases: [String: String] = [
        "hbf": "hauptbahnhof",
        "bhf": "bahnhof"
    ]

    private init() {
        let names = Self.loadStationNames()
        normalized = names.map { ($0, Self.fold($0)) }
        let count = normalized.count
        Self.logger.info("Loaded station index with \(count, privacy: .public) names")
    }

    func matches(for query: String, role: StationRole? = nil, limit: Int) -> [String] {
        let q = expandAbbreviations(in: Self.fold(query))
        guard !q.isEmpty else { return [] }

        var ranked = normalized
        if let role {
            let roleHint = role == .from ? "wien" : "salzburg"
            ranked.sort { lhs, rhs in
                let lhsScore = lhs.folded.contains(roleHint) ? 1 : 0
                let rhsScore = rhs.folded.contains(roleHint) ? 1 : 0
                return lhsScore > rhsScore
            }
        }

        let prefix = ranked
            .filter { expandAbbreviations(in: $0.folded).hasPrefix(q) }
            .map(\.original)

        if prefix.count >= limit {
            let result = Array(prefix.prefix(limit))
            Self.logger.debug("Prefix station match query='\(query, privacy: .public)' role='\(role?.rawValue ?? "-", privacy: .public)' count=\(result.count, privacy: .public)")
            return result
        }

        let contains = ranked
            .filter {
                let value = expandAbbreviations(in: $0.folded)
                return value.contains(q) && !value.hasPrefix(q)
            }
            .map(\.original)

        let fuzzy = ranked
            .compactMap { entry -> (name: String, score: Int)? in
                let value = expandAbbreviations(in: entry.folded)
                if value.hasPrefix(q) || value.contains(q) {
                    return nil
                }
                let score = Self.fuzzyScore(query: q, candidate: value)
                guard score > 0 else { return nil }
                return (entry.original, score)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .map(\.name)

        let result = Array((prefix + contains + fuzzy).prefix(limit))
        Self.logger.debug("Station match query='\(query, privacy: .public)' role='\(role?.rawValue ?? "-", privacy: .public)' count=\(result.count, privacy: .public)")
        return result
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
        guard distance <= 1 else { return nil }

        // Lower than true subsequence/prefix hits, but enough to keep the preview badge alive
        // while users fix a small typo (e.g. "wiee" -> "wien").
        return 65 - distance * 12 + min(q.count, 10)
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

    private func expandAbbreviations(in value: String) -> String {
        value
            .split(separator: " ")
            .map { part in aliases[String(part)] ?? String(part) }
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
