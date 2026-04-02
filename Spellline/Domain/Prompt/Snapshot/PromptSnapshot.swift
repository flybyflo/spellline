import Foundation
import OSLog
import UIKit

// MARK: - Snapshot

struct InlineTokenPresentation {
    let token: InlineToken
    let storageLocation: Int
    /// UTF-16 length of this token’s run in `attributedText` (glyphs backing the overlay frame).
    let storageLength: Int
    let size: CGSize
    /// Unused when station text lives in `NSTextStorage` (system caret); kept for call-site compatibility.
    let stationCaretLeadingTextWidth: CGFloat?
}

struct RenderedEditorSnapshot {
    private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "PromptSnapshot")
    var attributedText: NSAttributedString
    var storageToPlain: [RangeMapEntry]
    var tokenHits: [Int: UUID]
    var presentations: [InlineTokenPresentation]
    var totalStorageLength: Int
    var caretStoragePosition: Int?
    /// Legacy: station text now lives in storage, so the system caret is shown. Kept for snapshot compatibility.
    var hidesSystemCaretForStationEditing: Bool

    static let empty = RenderedEditorSnapshot(
        attributedText: NSAttributedString(),
        storageToPlain: [],
        tokenHits: [:],
        presentations: [],
        totalStorageLength: 0,
        caretStoragePosition: nil,
        hidesSystemCaretForStationEditing: false
    )

    func mapStorageRangeToPlain(_ storageRange: NSRange) -> NSRange {
        let a = storageRange.location
        let b = storageRange.location + storageRange.length
        let startPlain = mapStoragePositionToPlain(a)
        if storageRange.length == 0 {
            return NSRange(location: startPlain, length: 0)
        }
        let endPlain = mapStoragePositionToPlain(b)
        return NSRange(location: startPlain, length: max(0, endPlain - startPlain))
    }

    /// Maps a storage index (caret index or range boundary) to the corresponding plain-text index.
    func mapStoragePositionToPlain(_ storagePos: Int) -> Int {
        var storageCursor = 0
        var plainCursor = 0

        for entry in storageToPlain {
            if entry.plainRange.location > plainCursor {
                let gapPlain = entry.plainRange.location - plainCursor
                let gapEndStorage = storageCursor + gapPlain
                if storagePos < gapEndStorage {
                    return plainCursor + (storagePos - storageCursor)
                }
                storageCursor += gapPlain
                plainCursor += gapPlain
            }

            let pLoc = entry.plainRange.location
            let pLen = entry.plainRange.length
            let pEnd = pLoc + pLen
            let sLoc = entry.storageRange.location
            let sLen = entry.storageRange.length
            let sEnd = sLoc + sLen

            if storagePos < sEnd {
                if entry.tokenID != nil {
                    let lead = entry.storageLeadingPaddingLength
                    let trail = entry.storageTrailingPaddingLength
                    let bodyStart = sLoc + lead
                    let bodyEnd = sEnd - trail
                    if sLen == 1 && pLen > 1 {
                        return pLoc
                    }
                    if lead > 0 || trail > 0 {
                        if storagePos < bodyStart {
                            Self.logger.debug("mapStoragePositionToPlain storagePos=\(storagePos, privacy: .public) hit leading padded token plain=\(pLoc, privacy: .public)")
                            return pLoc
                        }
                        if storagePos < bodyEnd {
                            let mapped = pLoc + (storagePos - bodyStart)
                            Self.logger.debug("mapStoragePositionToPlain storagePos=\(storagePos, privacy: .public) bodyStart=\(bodyStart, privacy: .public) -> plain=\(mapped, privacy: .public)")
                            return mapped
                        }
                        Self.logger.debug("mapStoragePositionToPlain storagePos=\(storagePos, privacy: .public) hit trailing padded token plainEnd=\(pEnd, privacy: .public)")
                        return pEnd
                    }
                    if sLen == pLen {
                        return pLoc + (storagePos - sLoc)
                    }
                    return pLoc
                }
                return pLoc + (storagePos - sLoc)
            }
            if storagePos == sEnd {
                return pEnd
            }
            plainCursor = pEnd
            storageCursor = sEnd
        }
        return plainCursor + (storagePos - storageCursor)
    }

    func mapPlainPositionToStorage(_ plainPos: Int) -> Int {
        var storageCursor = 0
        var plainCursor = 0

        for entry in storageToPlain {
            if entry.plainRange.location > plainCursor {
                let gapPlain = entry.plainRange.location - plainCursor
                if plainPos < plainCursor + gapPlain {
                    return storageCursor + (plainPos - plainCursor)
                }
                storageCursor += gapPlain
                plainCursor += gapPlain
            }

            let pLoc = entry.plainRange.location
            let pLen = entry.plainRange.length
            let pEnd = pLoc + pLen
            let sLoc = entry.storageRange.location
            let sLen = entry.storageRange.length
            let sEnd = sLoc + sLen

            if plainPos < pEnd {
                if entry.tokenID != nil {
                    let lead = entry.storageLeadingPaddingLength
                    let trail = entry.storageTrailingPaddingLength
                    let bodyStart = sLoc + lead
                    let bodyEnd = sEnd - trail
                    if sLen == 1 && pLen > 1 {
                        return sLoc
                    }
                    if lead > 0 || trail > 0 {
                        let mapped = bodyStart + (plainPos - pLoc)
                        Self.logger.debug("mapPlainPositionToStorage plainPos=\(plainPos, privacy: .public) bodyStart=\(bodyStart, privacy: .public) -> storage=\(mapped, privacy: .public)")
                        return mapped
                    }
                    if sLen == pLen {
                        return sLoc + (plainPos - pLoc)
                    }
                    return sLoc
                }
                return sLoc + (plainPos - pLoc)
            }
            if plainPos == pEnd {
                if entry.tokenID != nil {
                    let lead = entry.storageLeadingPaddingLength
                    let trail = entry.storageTrailingPaddingLength
                    if lead > 0 || trail > 0 {
                        let mapped = sEnd - trail
                        Self.logger.debug("mapPlainPositionToStorage plainPos=end \(plainPos, privacy: .public) -> storage=\(mapped, privacy: .public)")
                        return mapped
                    }
                }
                return sEnd
            }
            plainCursor = pEnd
            storageCursor = sEnd
        }
        return storageCursor + (plainPos - plainCursor)
    }

    func tokenID(atOrAdjacentCaretStoragePosition storagePosition: Int) -> UUID? {
        if let direct = tokenHits[storagePosition] {
            return direct
        }
        if storagePosition > 0, let previous = tokenHits[storagePosition - 1] {
            return previous
        }
        return nil
    }

    func presentation(for tokenID: UUID) -> InlineTokenPresentation? {
        presentations.first { $0.token.id == tokenID }
    }

    /// Station caret indices are inside the station storage run only; the trailing end boundary counts as outside.
    func stationPresentationContainingCaret(storagePosition: Int) -> InlineTokenPresentation? {
        for p in presentations {
            guard p.token.kind == .station else { continue }
            let s = p.storageLocation
            let end = s + p.storageLength
            if storagePosition >= s && storagePosition < end {
                Self.logger.debug("stationPresentationContainingCaret storagePosition=\(storagePosition, privacy: .public) token=\(p.token.id.uuidString, privacy: .public) range=[\(s, privacy: .public),\(end, privacy: .public))")
                return p
            }
        }
        return nil
    }

    func stationPresentationAtTrailingExitPosition(storagePosition: Int) -> InlineTokenPresentation? {
        for entry in storageToPlain {
            guard let tokenID = entry.tokenID, entry.storageTrailingPaddingLength > 0 else { continue }
            let trailingStart = entry.storageRange.location + entry.storageRange.length - entry.storageTrailingPaddingLength
            let trailingEnd = entry.storageRange.location + entry.storageRange.length
            guard storagePosition >= trailingStart && storagePosition < trailingEnd else { continue }
            guard let presentation = presentation(for: tokenID), presentation.token.kind == .station else { continue }
            Self.logger.debug(
                "stationPresentationAtTrailingExitPosition storagePosition=\(storagePosition, privacy: .public) token=\(tokenID.uuidString, privacy: .public) trailing=[\(trailingStart, privacy: .public),\(trailingEnd, privacy: .public))"
            )
            return presentation
        }
        return nil
    }
}

struct RangeMapEntry {
    var storageRange: NSRange
    var plainRange: NSRange
    var tokenID: UUID?
    /// UTF-16 length of storage glyphs before the plain-text body (station icon column filler).
    var storageLeadingPaddingLength: Int = 0
    /// UTF-16 length of storage glyphs after the plain-text body (station trailing filler).
    var storageTrailingPaddingLength: Int = 0
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

// MARK: - Station inline text (clear glyphs; badge draws visible copy)

enum InlineStationStorage {
    struct RenderedRun {
        let attributedString: NSAttributedString
        let leadingPaddingUTF16Length: Int
        let trailingPaddingUTF16Length: Int
    }

    /// Matches `InlineStationTokenView`: inner leading inset + icon + gap before the label/menu.
    static let inlineTextLeadingInset: CGFloat = 8 + 16 + 8

    /// Leading spacer + body use `LayoutMetrics.inlineBadgeFont` (same size/weight as chip labels), not editor body font.
    /// Leading invisible spacer (icon column) + UTF-16 body + optional trailing spacer so the caret can stop
    /// at the end of the visible text without jumping to the padded end of the badge.
    static func renderedRun(
        plainSubstring: String,
        targetWidth: CGFloat,
        font: UIFont,
        paragraphStyle: NSParagraphStyle
    ) -> RenderedRun {
        let leadingW = min(inlineTextLeadingInset, max(0, targetWidth - 1))
        let bodyBudget = max(0, targetWidth - leadingW)
        let leading = InlineSpacerRun.make(width: leadingW, font: font, paragraphStyle: paragraphStyle)

        if plainSubstring.isEmpty {
            let result = NSMutableAttributedString(attributedString: leading)
            result.append(InlineSpacerRun.make(width: bodyBudget, font: font, paragraphStyle: paragraphStyle))
            return RenderedRun(
                attributedString: result,
                leadingPaddingUTF16Length: 1,
                trailingPaddingUTF16Length: 1
            )
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.clear,
            .paragraphStyle: paragraphStyle
        ]
        let body = NSMutableAttributedString(string: plainSubstring, attributes: attrs)
        let textW = stringWidth(plainSubstring, font: font)
        let extra = max(0, bodyBudget - textW)
        let result = NSMutableAttributedString(attributedString: leading)
        result.append(body)
        if extra > 0 {
            result.append(InlineSpacerRun.make(width: extra, font: font, paragraphStyle: paragraphStyle))
        }
        return RenderedRun(
            attributedString: result,
            leadingPaddingUTF16Length: 1,
            trailingPaddingUTF16Length: extra > 0 ? 1 : 0
        )
    }

    /// One NBSP + kern; matches the leading spacer we prepend.
    static let leadingPaddingUTF16Length: Int = 1

    private static func stringWidth(_ string: String, font: UIFont) -> CGFloat {
        let rect = (string as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.width)
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
            let typed = token.matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = token.label

            let typedWidth = width(of: typed, font: font)
            let resolvedWidth = width(of: resolved, font: font)

            let foldedTyped = typed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let foldedResolved = resolved.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            // Same visual row width while typing a prefix of the resolved name or when finished — do not switch
            // to a different formula on the last keystroke (`isAccepted`), or the badge width jumps.
            let isAlignedWithPrediction = typed.isEmpty || foldedResolved.hasPrefix(foldedTyped)

            let chrome = presetChipHorizontalChrome
            let maxStationWidth = min(max(220, metrics.editorTextColumnWidth), 420)
            let cursorReserve: CGFloat = 8
            let typoReserve = isAlignedWithPrediction ? 0 : width(of: "WW", font: font)

            let contentWidth = max(
                resolvedWidth + cursorReserve,
                typedWidth + typoReserve + cursorReserve
            )

            return CGSize(
                width: min(max(contentWidth + chrome, 96), maxStationWidth),
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
