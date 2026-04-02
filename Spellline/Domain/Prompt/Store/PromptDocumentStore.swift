import Foundation
import Observation
import OSLog
import UIKit

// MARK: - Store

@MainActor
@Observable
final class PromptDocumentStore {
    private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "PromptDocumentStore")
    var document: PromptDocument

    @ObservationIgnored
    private(set) var snapshot: RenderedEditorSnapshot = .empty

    /// Dismissed badge spans: same `semanticKey` + `matchedText` can re-badge only after invalidation (e.g. typing after the span).
    private var rejectedDismissals: [String: NSRange] = [:]
    private let autoAcceptConfidence = 0.95
    private let matcher: PromptMatching
    private var pendingCaretPlainPosition: Int?
    private var logicalCaretPlainPositionValue: Int?

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
        Self.logger.debug(
            "applyEdit plainRange=(\(plainRange.location, privacy: .public),\(plainRange.length, privacy: .public)) safeRange=(\(safeRange.location, privacy: .public),\(safeRange.length, privacy: .public)) replacement='\(replacementText, privacy: .public)' delta=\(delta, privacy: .public)"
        )

        updateRejectedDismissalsForEdit(safeRange: safeRange, replacementText: replacementText, delta: delta)

        document.tokens.removeAll { token in
            let intersects = NSIntersectionRange(token.plainRange, safeRange).length > 0
            // Keep station tokens during in-place typing edits so reconcile can preserve token identity.
            // This prevents station badge teardown/recreation flicker on each keystroke.
            return intersects && token.kind != .station
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
        let nextCaret = safeRange.location + (replacementText as NSString).length
        pendingCaretPlainPosition = nextCaret
        logicalCaretPlainPositionValue = nextCaret
        Self.logger.debug("applyEdit nextCaret plain=\(nextCaret, privacy: .public)")

        rebuildDocument()
    }

    func setLogicalCaretPlainPosition(_ position: Int?) {
        guard let position else {
            logicalCaretPlainPositionValue = nil
            Self.logger.debug("setLogicalCaretPlainPosition cleared")
            return
        }

        let length = (document.plainText as NSString).length
        logicalCaretPlainPositionValue = max(0, min(position, length))
        Self.logger.debug("setLogicalCaretPlainPosition requested=\(position, privacy: .public) stored=\(self.logicalCaretPlainPositionValue ?? -1, privacy: .public)")
    }

    func clearLogicalCaretPlainPosition() {
        logicalCaretPlainPositionValue = nil
        Self.logger.debug("clearLogicalCaretPlainPosition")
    }

    func clearPendingCaretPlainPosition() {
        pendingCaretPlainPosition = nil
        Self.logger.debug("clearPendingCaretPlainPosition")
    }

    func logicalCaretPlainPosition(in token: InlineToken) -> Int {
        let start = token.plainRange.location
        let end = token.plainRange.upperBound
        let raw = logicalCaretPlainPositionValue ?? end
        return max(start, min(raw, end))
    }

    func hasLogicalCaretPlainPosition() -> Bool {
        logicalCaretPlainPositionValue != nil
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
        let stationLivePreviews = unresolved.filter { candidate in
            candidate.kind == .station && candidate.confidence >= autoAcceptConfidence
        }

        var seenMaterializedCandidateIDs: Set<UUID> = []
        let candidatesToMaterialize = (autoAccepted + stationLivePreviews).filter { candidate in
            seenMaterializedCandidateIDs.insert(candidate.id).inserted
        }

        if !candidatesToMaterialize.isEmpty {
            nextTokens.append(contentsOf: candidatesToMaterialize.map(makeToken(from:)))
            let secondPass = reconcileTokens(existing: nextTokens, with: resolved)
            nextTokens = secondPass.tokens
        }

        document.tokens = nextTokens.sorted { $0.plainRange.location < $1.plainRange.location }
    }

    func buildSnapshot(metrics: LayoutMetrics) {
        Self.logger.debug(
            "buildSnapshot textLength=\((self.document.plainText as NSString).length, privacy: .public) tokenCount=\(self.document.tokens.count, privacy: .public) pendingCaret=\(self.pendingCaretPlainPosition ?? -1, privacy: .public) logicalCaret=\(self.logicalCaretPlainPositionValue ?? -1, privacy: .public)"
        )
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

            let tokenAttributed: NSAttributedString
            let storageLength: Int
            var stationLeadingPaddingLength = 0
            var stationTrailingPaddingLength = 0
            if token.kind == .station {
                let stationPlain = nsPlain.substring(with: token.plainRange)
                Self.logger.debug(
                    "buildSnapshot station token id=\(token.id.uuidString, privacy: .public) plain='\(stationPlain, privacy: .public)' matched='\(token.matchedText, privacy: .public)' label='\(token.label, privacy: .public)' tokenSize=\(Int(tokenSize.width), privacy: .public)x\(Int(tokenSize.height), privacy: .public)"
                )
                let stationRun = InlineStationStorage.renderedRun(
                    plainSubstring: stationPlain,
                    targetWidth: tokenSize.width,
                    font: metrics.inlineBadgeFont,
                    paragraphStyle: paragraphStyle
                )
                tokenAttributed = stationRun.attributedString
                storageLength = (tokenAttributed.string as NSString).length
                stationLeadingPaddingLength = stationRun.leadingPaddingUTF16Length
                stationTrailingPaddingLength = stationRun.trailingPaddingUTF16Length
            } else {
                tokenAttributed = InlineSpacerRun.make(width: tokenSize.width, font: editorFont, paragraphStyle: paragraphStyle)
                storageLength = 1
            }

            result.append(tokenAttributed)

            for offset in 0..<storageLength {
                tokenHits[storageCursor + offset] = token.id
            }
            rangeMap.append(
                RangeMapEntry(
                    storageRange: NSRange(location: storageCursor, length: storageLength),
                    plainRange: token.plainRange,
                    tokenID: token.id,
                    storageLeadingPaddingLength: stationLeadingPaddingLength,
                    storageTrailingPaddingLength: stationTrailingPaddingLength
                )
            )

            presentations.append(
                InlineTokenPresentation(
                    token: token,
                    storageLocation: storageCursor,
                    storageLength: storageLength,
                    size: tokenSize,
                    stationCaretLeadingTextWidth: nil
                )
            )

            storageCursor += storageLength
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
            caretStoragePosition: nil,
            hidesSystemCaretForStationEditing: false
        )

        if let caretPlain = pendingCaretPlainPosition {
            newSnapshot.caretStoragePosition = newSnapshot.mapPlainPositionToStorage(caretPlain)
            Self.logger.debug("buildSnapshot pending caret plain=\(caretPlain, privacy: .public) -> storage=\(newSnapshot.caretStoragePosition ?? -1, privacy: .public)")
            pendingCaretPlainPosition = nil
        }

        // Forward typing: `pendingCaretPlainPosition` is only set on `applyEdit`. A second `buildSnapshot`
        // (e.g. SwiftUI `updateUIView` after `renderSignature` changes) would otherwise leave
        // `caretStoragePosition` nil, `updateUIView` corrupts `selectedRange`, and `textViewDidChangeSelection`
        // clears the logical caret — hiding the in-badge caret while the system caret stays wrong.
        if newSnapshot.caretStoragePosition == nil, let lc = logicalCaretPlainPositionValue {
            newSnapshot.caretStoragePosition = newSnapshot.mapPlainPositionToStorage(lc)
            Self.logger.debug("buildSnapshot logical caret plain=\(lc, privacy: .public) -> storage=\(newSnapshot.caretStoragePosition ?? -1, privacy: .public)")
        }

        snapshot = newSnapshot
        Self.logger.debug("buildSnapshot complete totalStorageLength=\(self.snapshot.totalStorageLength, privacy: .public) caretStorage=\(self.snapshot.caretStoragePosition ?? -1, privacy: .public)")
    }

    func updateTokenValue(id: UUID, value: CheatValue) {
        guard let index = document.tokens.firstIndex(where: { $0.id == id }) else { return }
        Self.logger.debug("updateTokenValue id=\(id.uuidString, privacy: .public)")

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

        let nextCaret = document.tokens[index].plainRange.location + document.tokens[index].plainRange.length
        pendingCaretPlainPosition = nextCaret
        logicalCaretPlainPositionValue = nextCaret
        rebuildDocument()
    }

    func removeToken(id: UUID) {
        guard let token = document.tokens.first(where: { $0.id == id }) else { return }
        rejectedDismissals[dismissalKey(semanticKey: token.semanticKey, matchedText: token.matchedText)] = token.plainRange
        pendingCaretPlainPosition = token.plainRange.upperBound
        logicalCaretPlainPositionValue = nil
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
