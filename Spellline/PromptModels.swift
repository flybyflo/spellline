//
//  PromptModels.swift
//  Spellline
//
//  Created by Florian Ritzmaier on 29.03.26.
//

import Foundation
import Observation
import OSLog
import SQLite3
import SwiftUI
import UIKit

// MARK: - Canonical Document Model

struct PromptDocument {
    var plainText: String
    var tokens: [InlineToken]
}

struct InlineToken: Identifiable, Hashable {
    let id: UUID
    var kind: CheatKind
    var value: CheatValue
    var displayStyle: CheatDisplayStyle
    var semanticKey: String
    var plainRange: NSRange
    var matchedText: String
    var commitsOnDelimiter: Bool = false

    var label: String {
        switch (kind, value) {
        case (.tag, .tag(let name)):
            return name
        case (.count, .int(let count)):
            return "\(count)"
        case (.numberWithUnit, .angle(let value)):
            return "\(Int(value))°"
        case (.timer, .seconds(let value)):
            return "\(value)s"
        case (.preset, .preset(let preset)):
            return preset.rawValue
        case (.background, .percentage(let amount)):
            return "\(Int(amount * 100))%"
        case (.size, .size(let size)):
            return size.rawValue
        case (.status, .status(let message)):
            return message
        case (.clock, .timeOfDay(let h, let m, let pm)):
            return CheatValue.formatTimeOfDay(hour12: h, minute: m, isPM: pm)
        case (.station, .station(_, let name)):
            return name
        default:
            return matchedText
        }
    }

    var iconName: String {
        switch kind {
        case .tag:
            return "tag.fill"
        case .count:
            return "number.square.fill"
        case .numberWithUnit:
            return "rotate.3d.fill"
        case .timer:
            return "timer"
        case .preset:
            return "camera.filters"
        case .background:
            return "paintpalette.fill"
        case .size:
            return "arrow.up.left.and.arrow.down.right"
        case .status:
            return "exclamationmark.triangle.fill"
        case .clock:
            return "clock.fill"
        case .station:
            if case .station(let role, _) = value {
                return role == .from ? "arrow.right.circle.fill" : "flag.checkered.circle.fill"
            }
            return "tram.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .tag:
            return Color(red: 0.25, green: 0.46, blue: 0.95)
        case .count:
            return Color(red: 0.15, green: 0.62, blue: 0.46)
        case .numberWithUnit:
            return Color(red: 0.91, green: 0.34, blue: 0.29)
        case .timer:
            return Color(red: 0.75, green: 0.47, blue: 0.14)
        case .preset:
            return Color(red: 0.49, green: 0.27, blue: 0.86)
        case .background:
            return Color(red: 0.02, green: 0.52, blue: 0.82)
        case .size:
            return Color(red: 0.83, green: 0.23, blue: 0.49)
        case .status:
            return Color(red: 0.48, green: 0.30, blue: 0.04)
        case .clock:
            return Color(red: 0.08, green: 0.52, blue: 0.48)
        case .station:
            return Color(red: 0.16, green: 0.38, blue: 0.82)
        }
    }

    var uiTint: UIColor {
        UIColor(tint)
    }

    var intValue: Int {
        switch value {
        case .int(let value):
            return value
        case .angle(let value):
            return Int(value)
        case .seconds(let value):
            return value
        default:
            return 0
        }
    }

    var doubleValue: Double {
        switch value {
        case .percentage(let value):
            return value
        default:
            return 0
        }
    }

    var plainTextValue: String {
        CheatNode.plainTextValue(for: value, semanticKey: semanticKey)
    }
}

// MARK: - Snapshot

struct InlineTokenPresentation {
    let token: InlineToken
    let storageLocation: Int
    let size: CGSize
}

struct RenderedEditorSnapshot {
    var attributedText: NSAttributedString
    var storageToPlain: [RangeMapEntry]
    var tokenHits: [Int: UUID]
    var presentations: [InlineTokenPresentation]
    var totalStorageLength: Int
    var caretStoragePosition: Int?

    static let empty = RenderedEditorSnapshot(
        attributedText: NSAttributedString(),
        storageToPlain: [],
        tokenHits: [:],
        presentations: [],
        totalStorageLength: 0,
        caretStoragePosition: nil
    )

    func mapStorageRangeToPlain(_ storageRange: NSRange) -> NSRange {
        let storageStart = storageRange.location
        let storageEnd = storageRange.location + storageRange.length

        var plainStart = storageStart
        var plainEnd = storageEnd

        for entry in storageToPlain {
            let sLoc = entry.storageRange.location
            let sEnd = sLoc + entry.storageRange.length
            let pLoc = entry.plainRange.location
            let pEnd = pLoc + entry.plainRange.length

            guard entry.tokenID != nil else { continue }

            if storageStart >= sEnd {
                plainStart += (pEnd - pLoc) - (sEnd - sLoc)
            } else if storageStart > sLoc && storageStart < sEnd {
                plainStart = pLoc
            }

            if storageEnd >= sEnd {
                plainEnd += (pEnd - pLoc) - (sEnd - sLoc)
            } else if storageEnd > sLoc && storageEnd < sEnd {
                plainEnd = pEnd
            }
        }

        plainStart = max(0, plainStart)
        plainEnd = max(plainStart, plainEnd)
        return NSRange(location: plainStart, length: plainEnd - plainStart)
    }

    func mapPlainPositionToStorage(_ plainPos: Int) -> Int {
        var storagePos = plainPos

        for entry in storageToPlain {
            guard entry.tokenID != nil else { continue }
            let pLoc = entry.plainRange.location
            let pEnd = pLoc + entry.plainRange.length

            if plainPos > pLoc {
                if plainPos >= pEnd {
                    storagePos -= (pEnd - pLoc) - 1
                } else {
                    storagePos = entry.storageRange.location
                    break
                }
            }
        }

        return max(0, storagePos)
    }
}

struct RangeMapEntry {
    var storageRange: NSRange
    var plainRange: NSRange
    var tokenID: UUID?
}

// MARK: - Inline Spacer (text run, not attachment)

enum InlineSpacerRun {
    static func make(width: CGFloat, font: UIFont, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let spacer = "\u{00A0}"
        let baseWidth = (spacer as NSString).size(withAttributes: [.font: font]).width
        let extraKern = max(0, width - baseWidth)

        return NSAttributedString(
            string: spacer,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.clear,
                .kern: extraKern,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}

// MARK: - Inline Sizing

enum InlineTokenSizing {
    /// Matches `InlineTagTokenView` / `InlineStatusTokenView`: leading inset + icon + gap + trailing inset.
    private static let textBadgeHorizontalChrome: CGFloat = 12 + 16 + 8 + 12
    /// Matches `InlinePresetTokenView`: inner inset + icon + gap + trailing inset + menu `contentInsets.trailing` (4).
    private static let presetChipHorizontalChrome: CGFloat = 8 + 16 + 8 + 8 + 4
    /// Matches `InlineTimeWheelTokenView`: leading/trailing inset + label–chevron gap + chevron (no leading icon).
    private static let clockChipHorizontalChrome: CGFloat = 12 + 12 + 4 + 9
    /// Extra width so `… AM` / `… PM` is not visually tight against the chevron.
    private static let clockLabelBreathingRoom: CGFloat = 10

    static func size(for token: InlineToken, metrics: LayoutMetrics) -> CGSize {
        let font = UIFont.systemFont(ofSize: metrics.inlineControlFontSize, weight: .bold)
        let labelWidth = width(of: token.label, font: font)
        let height = metrics.inlineControlHeight

        switch token.kind {
        case .count, .timer, .numberWithUnit:
            return CGSize(width: 110, height: height)

        case .background:
            // Slider min track + label for "100%", + insets + gap (matches `InlineSliderTokenView` / `LayoutMetrics.sliderWidth`).
            let percentLabelW = width(of: "100%", font: font) + 2
            let backgroundSliderChrome: CGFloat = 10 + 10 + 8 + metrics.sliderWidth
            return CGSize(width: backgroundSliderChrome + percentLabelW, height: height)

        case .preset:
            let maxOptionWidth = FilterPreset.allCases
                .map { width(of: $0.rawValue, font: font) }
                .max() ?? 0
            return CGSize(
                width: min(maxOptionWidth + presetChipHorizontalChrome, 260),
                height: height
            )

        case .size:
            return CGSize(width: 104, height: height)

        case .status:
            return CGSize(
                width: min(labelWidth + textBadgeHorizontalChrome, 260),
                height: height
            )

        case .tag:
            return CGSize(
                width: min(labelWidth + textBadgeHorizontalChrome, 220),
                height: height
            )

        case .clock:
            return CGSize(
                width: min(
                    max(labelWidth + clockLabelBreathingRoom + clockChipHorizontalChrome, 128),
                    metrics.clockChipMaxWidth
                ),
                height: height
            )
        case .station:
            return CGSize(
                width: min(max(labelWidth + presetChipHorizontalChrome + 24, 170), 320),
                height: height
            )
        }
    }

    private static func width(of text: String, font: UIFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return ceil(rect.width)
    }
}

// MARK: - Display Types

struct CheatNode: Identifiable, Hashable {
    let id: UUID
    var semanticKey: String
    var kind: CheatKind
    var value: CheatValue
    var displayStyle: CheatDisplayStyle
    var sourceRangeHint: NSRange?
    var label: String

    static func plainTextValue(for value: CheatValue, semanticKey: String) -> String {
        switch value {
        case .tag(let name):
            return name
        case .int(let count):
            return "\(count)"
        case .angle(let degrees):
            return "\(Int(degrees))°"
        case .seconds(let seconds):
            return "\(seconds)s"
        case .preset(let preset):
            return preset.rawValue
        case .percentage(let amount):
            if semanticKey.hasPrefix("percent:") {
                return "\(Int(round(amount * 100)))%"
            }
            return String(format: "%.1f", amount)
        case .size(let size):
            return size.rawValue.lowercased()
        case .status(let message):
            return message
        case .timeOfDay(let h, let m, let pm):
            return CheatValue.formatTimeOfDay(hour12: h, minute: m, isPM: pm)
        case .station(_, let name):
            return name
        }
    }
}

enum CheatKind: String, Hashable {
    case tag
    case size
    case count
    case numberWithUnit
    case timer
    case preset
    case background
    case status
    case clock
    case station
}

enum CheatValue: Hashable {
    case tag(String)
    case int(Int)
    case angle(Double)
    case seconds(Int)
    case preset(FilterPreset)
    case percentage(Double)
    case size(SizePreset)
    case status(String)
    case timeOfDay(hour12: Int, minute: Int, isPM: Bool)
    case station(role: StationRole, name: String)
}

enum StationRole: String, Hashable {
    case from
    case to
}

extension CheatValue {
    static func formatTimeOfDay(hour12: Int, minute: Int, isPM: Bool) -> String {
        let h = max(1, min(12, hour12))
        let m = max(0, min(59, minute))
        return "\(h):\(String(format: "%02d", m)) \(isPM ? "PM" : "AM")"
    }
}

enum CheatDisplayStyle: Hashable {
    case chip
    case stepper
    case slider
    case menu
    case badge
    case wheel
}

enum FilterPreset: String, CaseIterable, Hashable {
    case ascii = "ASCII"
    case bloom = "Bloom"
    case pixel = "Pixel"
    case crt = "CRT"
}

enum SizePreset: String, CaseIterable, Hashable {
    case smaller = "Smaller"
    case bigger = "Bigger"
}

// MARK: - Match Candidates

struct MatchCandidate: Identifiable, Hashable {
    let id: UUID
    let range: NSRange
    let semanticKey: String
    let kind: CheatKind
    let value: CheatValue
    let confidence: Double
    let displayStyle: CheatDisplayStyle
    let matchedText: String
    let commitsOnDelimiter: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MatchCandidate, rhs: MatchCandidate) -> Bool {
        lhs.id == rhs.id
    }
}

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
            pattern: "\\b(from|to)\\s+([^,.;\\n]+?)(?=\\s+\\b(?:from|to)\\b|[,.;\\n]|$)",
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
                guard rawQuery.count >= 2 else { continue }

                let options = StationSearchIndex.shared.matches(for: rawQuery, role: role, limit: 8)
                guard let best = options.first else { continue }
                let confidence: Double = best.caseInsensitiveCompare(rawQuery) == .orderedSame ? 1 : 0.98
                let autoAccept = shouldAutoAcceptStation(in: text, queryRange: queryRange, capturedQuery: capturedQuery)

                results.append(
                    MatchCandidate(
                        id: UUID(),
                        range: queryRange,
                        semanticKey: "station:\(role.rawValue):\(best.lowercased())",
                        kind: .station,
                        value: .station(role: role, name: best),
                        confidence: confidence,
                        displayStyle: .menu,
                        matchedText: nsText.substring(with: queryRange),
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
        // Keep station as live-completion while typing; commit when user typed a trailing space
        // or a hard delimiter after the query (punctuation/newline).
        if capturedQuery != capturedQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }

        let nsText = text as NSString
        let end = queryRange.location + queryRange.length
        guard end < nsText.length else { return false }
        let next = nsText.substring(with: NSRange(location: end, length: 1))
        guard let scalar = next.unicodeScalars.first else { return false }
        return CharacterSet.punctuationCharacters.union(.newlines).contains(scalar)
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

        let result = Array((prefix + contains).prefix(limit))
        Self.logger.debug("Station match query='\(query, privacy: .public)' role='\(role?.rawValue ?? "-", privacy: .public)' count=\(result.count, privacy: .public)")
        return result
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

// MARK: - Store

@MainActor
@Observable
final class PromptDocumentStore {
    var document: PromptDocument

    @ObservationIgnored
    private(set) var snapshot: RenderedEditorSnapshot = .empty

    /// Dismissed badge spans: same `semanticKey` + `matchedText` can re-badge only after invalidation (e.g. typing after the span).
    private var rejectedDismissals: [String: NSRange] = [:]
    private let autoAcceptConfidence = 0.95
    private let matcher: PromptMatching
    private var pendingCaretPlainPosition: Int?

    init(
        plainText: String = "make ogre bigger and spawn 4 each round, rotate 25° every 10s, apply ASCII filter, set background tint 0.8, flag collision warning, or try 80% at 8:00 PM",
        matcher: PromptMatching? = nil
    ) {
        self.document = PromptDocument(plainText: plainText, tokens: [])
        self.matcher = matcher ?? HeuristicPromptMatcher()
        rebuildDocument()
    }

    func renderSignature(metrics: LayoutMetrics) -> String {
        let tokenPart = document.tokens.map {
            let valueString: String
            switch $0.value {
            case .tag(let text): valueString = text
            case .int(let value): valueString = "\(value)"
            case .angle(let value): valueString = "\(value)"
            case .seconds(let value): valueString = "\(value)"
            case .preset(let preset): valueString = preset.rawValue
            case .percentage(let value): valueString = "\(value)"
            case .size(let size): valueString = size.rawValue
            case .status(let text): valueString = text
            case .timeOfDay(let h, let m, let pm):
                valueString = CheatValue.formatTimeOfDay(hour12: h, minute: m, isPM: pm)
            case .station(let role, let name):
                valueString = "\(role.rawValue):\(name)"
            }

            return "\($0.id.uuidString):\($0.semanticKey):\($0.plainRange.location):\($0.plainRange.length):\(valueString):\($0.commitsOnDelimiter)"
        }
        .joined(separator: ";")

        return [
            document.plainText,
            tokenPart,
            "\(Int(metrics.editorTextSize))",
            "\(Int(metrics.inlineControlHeight))",
            "\(Int(metrics.editorMinimumLineHeight))",
            "\(Int(metrics.clockPickerBarWidth))",
            "\(Int(metrics.clockChipMaxWidth))",
            "\(Int(metrics.inlineTokenVerticalNudge * 10))",
            "\(Int(metrics.inlineControlFontSize * 10))",
            "\(Int(metrics.sliderWidth))"
        ].joined(separator: "||")
    }

    func applyEdit(plainRange: NSRange, replacementText: String) {
        let nsText = NSMutableString(string: document.plainText)

        let safeLoc = min(plainRange.location, nsText.length)
        let safeLen = min(plainRange.length, nsText.length - safeLoc)
        let safeRange = NSRange(location: safeLoc, length: safeLen)
        let delta = (replacementText as NSString).length - safeRange.length

        updateRejectedDismissalsForEdit(safeRange: safeRange, replacementText: replacementText, delta: delta)

        document.tokens.removeAll { token in
            NSIntersectionRange(token.plainRange, safeRange).length > 0
        }

        for index in document.tokens.indices {
            if document.tokens[index].plainRange.location >= safeRange.location + safeRange.length {
                document.tokens[index].plainRange = NSRange(
                    location: document.tokens[index].plainRange.location + delta,
                    length: document.tokens[index].plainRange.length
                )
            }
        }

        nsText.replaceCharacters(in: safeRange, with: replacementText)
        document.plainText = nsText as String
        pendingCaretPlainPosition = safeRange.location + (replacementText as NSString).length

        rebuildDocument()
    }

    func rebuildDocument() {
        let raw = matcher.match(text: document.plainText)
        let resolved = MatchResolution.nonOverlappingGreedy(raw)

        let reconciled = reconcileTokens(existing: document.tokens, with: resolved)
        var nextTokens = reconciled.tokens

        let unresolved = resolved.filter { candidate in
            !reconciled.usedCandidateIDs.contains(candidate.id) &&
            !isDismissed(candidate: candidate)
        }

        let autoAccepted = unresolved.filter { candidate in
            candidate.confidence >= autoAcceptConfidence && !candidate.commitsOnDelimiter
        }
        if !autoAccepted.isEmpty {
            nextTokens.append(contentsOf: autoAccepted.map(makeToken(from:)))
            let secondPass = reconcileTokens(existing: nextTokens, with: resolved)
            nextTokens = secondPass.tokens
        }

        document.tokens = nextTokens.sorted { $0.plainRange.location < $1.plainRange.location }
    }

    func buildSnapshot(metrics: LayoutMetrics) {
        let plainText = document.plainText
        let nsPlain = plainText as NSString
        let tokens = document.tokens.sorted { $0.plainRange.location < $1.plainRange.location }

        let editorFont = UIFont.systemFont(ofSize: metrics.editorTextSize, weight: .medium)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = metrics.editorMinimumLineHeight
        paragraphStyle.lineSpacing = 4

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: editorFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString()
        var rangeMap: [RangeMapEntry] = []
        var tokenHits: [Int: UUID] = [:]
        var presentations: [InlineTokenPresentation] = []

        var plainCursor = 0
        var storageCursor = 0

        for token in tokens {
            let tokenStart = token.plainRange.location
            let tokenEnd = token.plainRange.location + token.plainRange.length

            guard tokenStart >= plainCursor else { continue }
            guard tokenEnd <= nsPlain.length else { continue }

            if tokenStart > plainCursor {
                let textChunk = nsPlain.substring(with: NSRange(location: plainCursor, length: tokenStart - plainCursor))
                let attrChunk = NSAttributedString(string: textChunk, attributes: baseAttributes)
                result.append(attrChunk)

                let textLength = (textChunk as NSString).length
                rangeMap.append(
                    RangeMapEntry(
                        storageRange: NSRange(location: storageCursor, length: textLength),
                        plainRange: NSRange(location: plainCursor, length: textLength),
                        tokenID: nil
                    )
                )
                storageCursor += textLength
            }

            let tokenSize = InlineTokenSizing.size(for: token, metrics: metrics)
            let spacerString = InlineSpacerRun.make(width: tokenSize.width, font: editorFont, paragraphStyle: paragraphStyle)
            result.append(spacerString)

            tokenHits[storageCursor] = token.id
            rangeMap.append(
                RangeMapEntry(
                    storageRange: NSRange(location: storageCursor, length: 1),
                    plainRange: token.plainRange,
                    tokenID: token.id
                )
            )

            presentations.append(
                InlineTokenPresentation(
                    token: token,
                    storageLocation: storageCursor,
                    size: tokenSize
                )
            )

            storageCursor += 1
            plainCursor = tokenEnd
        }

        if plainCursor < nsPlain.length {
            let trailingText = nsPlain.substring(from: plainCursor)
            let attrTrailing = NSAttributedString(string: trailingText, attributes: baseAttributes)
            result.append(attrTrailing)

            let trailingLength = (trailingText as NSString).length
            rangeMap.append(
                RangeMapEntry(
                    storageRange: NSRange(location: storageCursor, length: trailingLength),
                    plainRange: NSRange(location: plainCursor, length: trailingLength),
                    tokenID: nil
                )
            )
            storageCursor += trailingLength
        }

        var newSnapshot = RenderedEditorSnapshot(
            attributedText: result,
            storageToPlain: rangeMap,
            tokenHits: tokenHits,
            presentations: presentations,
            totalStorageLength: storageCursor,
            caretStoragePosition: nil
        )

        if let caretPlain = pendingCaretPlainPosition {
            newSnapshot.caretStoragePosition = newSnapshot.mapPlainPositionToStorage(caretPlain)
            pendingCaretPlainPosition = nil
        }

        snapshot = newSnapshot
    }

    func updateTokenValue(id: UUID, value: CheatValue) {
        guard let index = document.tokens.firstIndex(where: { $0.id == id }) else { return }

        let token = document.tokens[index]
        guard token.plainRange.location != NSNotFound else { return }
        guard token.plainRange.location + token.plainRange.length <= (document.plainText as NSString).length else { return }

        let replacement = CheatNode.plainTextValue(for: value, semanticKey: token.semanticKey)
        let delta = (replacement as NSString).length - token.plainRange.length

        let mutable = NSMutableString(string: document.plainText)
        mutable.replaceCharacters(in: token.plainRange, with: replacement)
        document.plainText = mutable as String

        document.tokens[index].value = value
        document.tokens[index].matchedText = replacement
        document.tokens[index].plainRange = NSRange(
            location: token.plainRange.location,
            length: (replacement as NSString).length
        )

        for otherIndex in document.tokens.indices where otherIndex != index {
            if document.tokens[otherIndex].plainRange.location > token.plainRange.location {
                document.tokens[otherIndex].plainRange = NSRange(
                    location: document.tokens[otherIndex].plainRange.location + delta,
                    length: document.tokens[otherIndex].plainRange.length
                )
            }
        }

        pendingCaretPlainPosition = document.tokens[index].plainRange.location + document.tokens[index].plainRange.length
        rebuildDocument()
    }

    func removeToken(id: UUID) {
        guard let token = document.tokens.first(where: { $0.id == id }) else { return }
        rejectedDismissals[dismissalKey(semanticKey: token.semanticKey, matchedText: token.matchedText)] = token.plainRange
        pendingCaretPlainPosition = token.plainRange.upperBound
        document.tokens.removeAll { $0.id == id }
        rebuildDocument()
    }

    private func dismissalKey(semanticKey: String, matchedText: String) -> String {
        "\(semanticKey)|\(matchedText.lowercased())"
    }

    private func isDismissed(candidate: MatchCandidate) -> Bool {
        let key = dismissalKey(semanticKey: candidate.semanticKey, matchedText: candidate.matchedText)
        guard let stored = rejectedDismissals[key] else { return false }
        return NSEqualRanges(stored, candidate.range)
    }

    private func updateRejectedDismissalsForEdit(safeRange: NSRange, replacementText: String, delta: Int) {
        let replaceLen = (replacementText as NSString).length
        let safeLoc = safeRange.location
        let safeEnd = safeRange.location + safeRange.length

        var keysToRemove: [String] = []
        for key in rejectedDismissals.keys {
            guard let rng = rejectedDismissals[key] else { continue }
            if replaceLen > 0 && safeRange.length == 0 && safeLoc == rng.upperBound {
                keysToRemove.append(key)
                continue
            }
            if NSIntersectionRange(safeRange, rng).length > 0 {
                keysToRemove.append(key)
                continue
            }
            if safeRange.length == 0 && replaceLen > 0 && safeLoc > rng.location && safeLoc < rng.upperBound {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            rejectedDismissals.removeValue(forKey: key)
        }

        for key in rejectedDismissals.keys {
            guard let rng = rejectedDismissals[key] else { continue }
            if rng.location >= safeEnd {
                rejectedDismissals[key] = NSRange(location: rng.location + delta, length: rng.length)
            }
        }
    }

    private func makeToken(from candidate: MatchCandidate) -> InlineToken {
        InlineToken(
            id: UUID(),
            kind: candidate.kind,
            value: candidate.value,
            displayStyle: candidate.displayStyle,
            semanticKey: candidate.semanticKey,
            plainRange: candidate.range,
            matchedText: candidate.matchedText,
            commitsOnDelimiter: candidate.commitsOnDelimiter
        )
    }

    private func reconcileTokens(
        existing: [InlineToken],
        with candidates: [MatchCandidate]
    ) -> (tokens: [InlineToken], usedCandidateIDs: Set<UUID>) {
        var remaining = candidates
        var updatedTokens: [InlineToken] = []
        var usedCandidateIDs: Set<UUID> = []

        for token in existing {
            guard let bestIndex = bestCandidateIndex(for: token, in: remaining) else {
                continue
            }

            let matchedCandidate = remaining.remove(at: bestIndex)
            usedCandidateIDs.insert(matchedCandidate.id)

            var updated = token
            updated.semanticKey = matchedCandidate.semanticKey
            updated.kind = matchedCandidate.kind
            updated.value = matchedCandidate.value
            updated.displayStyle = matchedCandidate.displayStyle
            updated.plainRange = matchedCandidate.range
            updated.matchedText = matchedCandidate.matchedText
            updated.commitsOnDelimiter = matchedCandidate.commitsOnDelimiter

            updatedTokens.append(updated)
        }

        return (updatedTokens, usedCandidateIDs)
    }

    private func bestCandidateIndex(for token: InlineToken, in candidates: [MatchCandidate]) -> Int? {
        var bestIndex: Int?
        var bestScore = Int.min

        for (index, candidate) in candidates.enumerated() {
            guard candidate.kind == token.kind else { continue }

            let overlap = NSIntersectionRange(candidate.range, token.plainRange).length
            let sameSemanticKey = candidate.semanticKey == token.semanticKey
            let sameText = candidate.matchedText.caseInsensitiveCompare(token.matchedText) == .orderedSame
            let rangeDistance = abs(candidate.range.location - token.plainRange.location)

            if !sameSemanticKey && overlap == 0 && !sameText {
                continue
            }

            var score = 0
            if sameSemanticKey { score += 1000 }
            if overlap > 0 { score += 200 + overlap }
            if sameText { score += 100 }
            if candidate.range == token.plainRange { score += 80 }
            score -= rangeDistance

            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        return bestIndex
    }
}

private extension NSRange {
    var upperBound: Int {
        location + length
    }
}
