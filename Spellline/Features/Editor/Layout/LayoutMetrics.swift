import UIKit

// MARK: - Layout Metrics

struct LayoutMetrics {
    let editorContentWidth: CGFloat

    static let screenPadding: CGFloat = 14

    var screenPadding: CGFloat { Self.screenPadding }
    var cardPadding: CGFloat { 14 }
    var controlPadding: CGFloat { 12 }
    var sectionSpacing: CGFloat { 16 }
    var inlineControlFontSize: CGFloat { 15.5 }
    var inlineControlHeight: CGFloat { 30 }
    /// Positive = move chips down to align optically with editor text (line-center reads a bit high).
    var inlineTokenVerticalNudge: CGFloat { 5 }
    var inlineIconSize: CGFloat { 15 }
    var cheatHorizontalPadding: CGFloat { 10 }
    var cheatVerticalPadding: CGFloat { 5 }
    var sliderWidth: CGFloat { 112 }
    var editorTextSize: CGFloat { 20 }
    var editorMinimumLineHeight: CGFloat { inlineControlHeight + 6 }
    var editorInset: CGFloat { 10 }
    var editorMinHeight: CGFloat { 160 }

    var editorTextColumnWidth: CGFloat {
        max(60, editorContentWidth - 2 * editorInset)
    }

    var clockPickerBarWidth: CGFloat {
        min(300, max(280, (editorTextColumnWidth * 0.62).rounded(.down)))
    }

    var clockChipMaxWidth: CGFloat {
        min(232, max(184, (editorTextColumnWidth * 0.5).rounded(.down)))
    }
}

extension UIColor {
    /// Lightens by mixing toward white in RGB (opacity unchanged — not the same as `withAlphaComponent`).
    func blendedTowardWhite(_ fraction: CGFloat) -> UIColor {
        let t = min(1, max(0, fraction))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return UIColor(
            red: r + (1 - r) * t,
            green: g + (1 - g) * t,
            blue: b + (1 - b) * t,
            alpha: a
        )
    }
}
