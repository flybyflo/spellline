import Foundation
import UIKit

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
