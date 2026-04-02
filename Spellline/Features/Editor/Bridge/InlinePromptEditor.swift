import Observation
import OSLog
import SwiftUI
import UIKit

// MARK: - Inline Prompt Editor

struct InlinePromptEditor: UIViewRepresentable {
    @Bindable var store: PromptDocumentStore
    let metrics: LayoutMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> InlineTokenTextView {
        let textView = InlineTokenTextView()
        textView.delegate = context.coordinator
        textView.inlineDelegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.keyboardDismissMode = .interactive
        textView.textDragInteraction?.isEnabled = false
        textView.allowsEditingTextAttributes = false
        textView.isFindInteractionEnabled = false
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
        textView.textContainerInset = UIEdgeInsets(
            top: metrics.editorInset,
            left: 0,
            bottom: metrics.editorInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.systemFont(ofSize: metrics.editorTextSize, weight: .medium)
        textView.clipsToBounds = false

        context.coordinator.textView = textView
        context.coordinator.parent = self

        store.buildSnapshot(metrics: metrics)
        textView.apply(
            snapshot: store.snapshot,
            metrics: metrics,
            animated: false,
            renderSignature: store.renderSignature(metrics: metrics)
        )
        textView.typingAttributes = context.coordinator.defaultTypingAttributes
        textView.syncSystemCaretVisibility()

        return textView
    }

    func updateUIView(_ uiView: InlineTokenTextView, context: Context) {
        context.coordinator.parent = self

        let signature = store.renderSignature(metrics: metrics)
        let selectedRange = uiView.selectedRange

        if uiView.currentRenderSignature != signature {
            store.buildSnapshot(metrics: metrics)
            uiView.apply(
                snapshot: store.snapshot,
                metrics: metrics,
                animated: true,
                renderSignature: signature
            )
        }

        uiView.typingAttributes = context.coordinator.defaultTypingAttributes

        if let caretPos = store.snapshot.caretStoragePosition {
            let safeCaret = min(caretPos, uiView.attributedText.length)
            let expected = context.coordinator.programmaticSelectionNeighborhood(
                around: safeCaret,
                maxLength: uiView.attributedText.length
            )
            context.coordinator.withProgrammaticSelection(expectedLocations: expected) {
                uiView.selectedRange = NSRange(location: safeCaret, length: 0)
            }
        } else {
            let maxLocation = min(selectedRange.location, uiView.attributedText.length)
            let maxLength = min(selectedRange.length, max(0, uiView.attributedText.length - maxLocation))
            let expected = context.coordinator.programmaticSelectionNeighborhood(
                around: maxLocation,
                maxLength: uiView.attributedText.length
            )
            context.coordinator.withProgrammaticSelection(expectedLocations: expected) {
                uiView.selectedRange = NSRange(location: maxLocation, length: maxLength)
            }
        }

        uiView.syncSystemCaretVisibility()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InlineTokenTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(metrics.editorMinHeight, fitting.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, InlineTokenTextViewDelegate {
        private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "InlinePromptEditor")
        var parent: InlinePromptEditor
        weak var textView: InlineTokenTextView?
        private var lastSelectionLocation: Int?
        private var expectedProgrammaticSelectionLocations: [Int] = []
        var defaultTypingAttributes: [NSAttributedString.Key: Any] {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.minimumLineHeight = parent.metrics.editorMinimumLineHeight
            paragraphStyle.lineSpacing = 4
            return [
                .font: UIFont.systemFont(ofSize: parent.metrics.editorTextSize, weight: .medium),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]
        }

        init(parent: InlinePromptEditor) {
            self.parent = parent
        }

        func withProgrammaticSelection(expectedLocations: [Int], _ body: () -> Void) {
            expectedProgrammaticSelectionLocations = Array(Set(expectedLocations)).sorted()
            body()
        }

        func programmaticSelectionNeighborhood(around location: Int, maxLength: Int) -> [Int] {
            let candidates = [location - 1, location, location + 1]
            return candidates.filter { $0 >= 0 && $0 <= maxLength }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn storageRange: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard let inlineTextView = textView as? InlineTokenTextView else {
                return true
            }

            let store = parent.store
            let snapshot = store.snapshot
            Self.logger.debug(
                "shouldChangeText storageRange=(\(storageRange.location, privacy: .public),\(storageRange.length, privacy: .public)) replacement='\(replacement, privacy: .public)' selected=\(textView.selectedRange.location, privacy: .public)"
            )

            if let stationToken = stationTokenForEditing(
                storageRange: storageRange,
                replacementText: replacement,
                snapshot: snapshot,
                store: store
            ) {
                Self.logger.debug(
                    "editing station token id=\(stationToken.id.uuidString, privacy: .public) matched='\(stationToken.matchedText, privacy: .public)' label='\(stationToken.label, privacy: .public)' plainRange=(\(stationToken.plainRange.location, privacy: .public),\(stationToken.plainRange.length, privacy: .public))"
                )
                if storageRange.length > 1 || (replacement as NSString).length > 1 {
                    let plainRange = snapshot.mapStorageRangeToPlain(storageRange)
                    Self.logger.debug(
                        "station multi-char edit mapped storageRange -> plainRange=(\(plainRange.location, privacy: .public),\(plainRange.length, privacy: .public))"
                    )
                    store.applyEdit(plainRange: plainRange, replacementText: replacement)
                    refreshEditor(animated: false, fallbackCaret: storageRange.location)
                    inlineTextView.typingAttributes = defaultTypingAttributes
                    inlineTextView.syncSystemCaretVisibility()
                    return false
                }

                let logicalCaret = store.logicalCaretPlainPosition(in: stationToken)
                Self.logger.debug("station logicalCaret=\(logicalCaret, privacy: .public)")

                if Self.shouldExitAcceptedStationOnTypedCharacter(
                    token: stationToken,
                    logicalCaret: logicalCaret,
                    replacement: replacement
                ) {
                    Self.logger.debug("station exit-on-typed-character triggered")
                    let insertRange = NSRange(location: stationToken.plainRange.upperBound, length: 0)
                    store.clearLogicalCaretPlainPosition()
                    store.applyEdit(plainRange: insertRange, replacementText: replacement)
                    refreshEditor(
                        animated: false,
                        fallbackCaret: storageRange.location + (replacement as NSString).length
                    )
                    inlineTextView.typingAttributes = defaultTypingAttributes
                    inlineTextView.syncSystemCaretVisibility()
                    return false
                }

                // Space: unique strong match, or double-space → best prediction; then one space after the badge.
                if replacement == " " {
                    if let commitValue = Self.commitStationValueIfUniqueMatch(token: stationToken) {
                        Self.logger.debug("station committed via unique match on space")
                        commitStationExitInsertingSpaceAfter(
                            stationToken: stationToken,
                            value: commitValue,
                            storageRange: storageRange,
                            inlineTextView: inlineTextView
                        )
                        return false
                    }
                    if Self.shouldCommitStationOnDoubleSpace(token: stationToken, logicalCaret: logicalCaret),
                       let commitValue = Self.commitStationWithBestPrediction(token: stationToken) {
                        Self.logger.debug("station committed via double-space best prediction")
                        commitStationExitInsertingSpaceAfter(
                            stationToken: stationToken,
                            value: commitValue,
                            storageRange: storageRange,
                            inlineTextView: inlineTextView
                        )
                        return false
                    }
                }

                if replacement.isEmpty {
                    guard logicalCaret > stationToken.plainRange.location else {
                        Self.logger.debug("station backspace ignored at leading edge")
                        return false
                    }

                    let deleteRange = NSRange(location: logicalCaret - 1, length: 1)
                    Self.logger.debug("station deleteRange=(\(deleteRange.location, privacy: .public),\(deleteRange.length, privacy: .public))")
                    store.applyEdit(plainRange: deleteRange, replacementText: "")
                    store.setLogicalCaretPlainPosition(deleteRange.location)
                } else {
                    let insertRange = NSRange(location: logicalCaret, length: 0)
                    Self.logger.debug("station insertRange=(\(insertRange.location, privacy: .public),\(insertRange.length, privacy: .public)) replacement='\(replacement, privacy: .public)'")
                    store.applyEdit(plainRange: insertRange, replacementText: replacement)
                    store.setLogicalCaretPlainPosition(logicalCaret + (replacement as NSString).length)
                }

                refreshEditor(animated: false, fallbackCaret: storageRange.location)
                inlineTextView.typingAttributes = defaultTypingAttributes
                inlineTextView.syncSystemCaretVisibility()
                return false
            }

            if replacement.isEmpty,
               storageRange.length == 1,
               let tokenID = snapshot.tokenHits[storageRange.location] {
                store.removeToken(id: tokenID)
                refreshEditor(animated: true, fallbackCaret: storageRange.location)
                inlineTextView.syncSystemCaretVisibility()
                return false
            }

            let plainRange = snapshot.mapStorageRangeToPlain(storageRange)
            Self.logger.debug(
                "normal edit mapped storageRange=(\(storageRange.location, privacy: .public),\(storageRange.length, privacy: .public)) -> plainRange=(\(plainRange.location, privacy: .public),\(plainRange.length, privacy: .public)) replacement='\(replacement, privacy: .public)'"
            )
            store.applyEdit(plainRange: plainRange, replacementText: replacement)
            store.clearLogicalCaretPlainPosition()
            refreshEditor(
                animated: false,
                fallbackCaret: storageRange.location + (replacement as NSString).length
            )

            inlineTextView.typingAttributes = defaultTypingAttributes
            inlineTextView.syncSystemCaretVisibility()
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let inlineTextView = textView as? InlineTokenTextView else { return }

            let snapshot = parent.store.snapshot
            let loc = textView.selectedRange.location
            let previousLoc = lastSelectionLocation
            let expectedIndex = expectedProgrammaticSelectionLocations.firstIndex(of: loc)
            let isProgrammaticSelection = expectedIndex != nil
            if let expectedIndex {
                expectedProgrammaticSelectionLocations.remove(at: expectedIndex)
            }
            lastSelectionLocation = loc
            Self.logger.debug(
                "selection changed previous=\(previousLoc ?? -1, privacy: .public) current=\(loc, privacy: .public) insideStationNow=\(snapshot.stationPresentationContainingCaret(storagePosition: loc) != nil, privacy: .public) programmatic=\(isProgrammaticSelection, privacy: .public) pending=\(self.expectedProgrammaticSelectionLocations.count, privacy: .public)"
            )

            let exitPresentation = snapshot.stationPresentationAtTrailingExitPosition(storagePosition: loc)

            if !isProgrammaticSelection,
               let previousLoc,
               let previousPresentation = snapshot.stationPresentationContainingCaret(storagePosition: previousLoc),
               (
                   snapshot.stationPresentationContainingCaret(storagePosition: loc) == nil ||
                   exitPresentation?.token.id == previousPresentation.token.id
               ),
               let stationToken = parent.store.document.tokens.first(where: { $0.id == previousPresentation.token.id }) {
                Self.logger.debug(
                    "selection exited station token id=\(stationToken.id.uuidString, privacy: .public) matched='\(stationToken.matchedText, privacy: .public)' label='\(stationToken.label, privacy: .public)'"
                )
                let commitValue =
                    Self.commitStationValueIfUniqueMatch(token: stationToken) ??
                    Self.commitStationWithBestPrediction(token: stationToken)
                if let commitValue {
                    Self.logger.debug("selection-exit commit triggered")
                    commitStationExitKeepingCaretOutside(
                        stationToken: stationToken,
                        value: commitValue,
                        inlineTextView: inlineTextView
                    )
                    inlineTextView.dimUnfocusedInlineViews()
                    inlineTextView.syncSystemCaretVisibility()
                    return
                }
            }

            if snapshot.stationPresentationContainingCaret(storagePosition: loc) != nil {
                let plainPos = snapshot.mapStoragePositionToPlain(loc)
                parent.store.setLogicalCaretPlainPosition(plainPos)
            } else {
                parent.store.clearLogicalCaretPlainPosition()
            }

            inlineTextView.dimUnfocusedInlineViews()
            inlineTextView.syncSystemCaretVisibility()
        }

        func inlineTokenViewDidRequestUpdate(id: UUID, value: CheatValue) {
            parent.store.updateTokenValue(id: id, value: value)
            refreshEditor(animated: true, fallbackCaret: parent.store.snapshot.caretStoragePosition ?? 0)
        }

        func inlineTokenViewDidRequestRemove(id: UUID) {
            parent.store.removeToken(id: id)
            refreshEditor(animated: true, fallbackCaret: parent.store.snapshot.caretStoragePosition ?? 0)
        }

        private func stationTokenForEditing(
            storageRange: NSRange,
            replacementText: String,
            snapshot: RenderedEditorSnapshot,
            store: PromptDocumentStore
        ) -> InlineToken? {
            let start = storageRange.location

            if storageRange.length > 1 {
                guard
                    let first = snapshot.stationPresentationContainingCaret(storagePosition: start),
                    let last = snapshot.stationPresentationContainingCaret(
                        storagePosition: start + storageRange.length - 1
                    ),
                    first.token.id == last.token.id
                else { return nil }
                return store.document.tokens.first { $0.id == first.token.id }
            }

            if let presentation = snapshot.stationPresentationContainingCaret(storagePosition: start) {
                return store.document.tokens.first { $0.id == presentation.token.id }
            }
            if replacementText.isEmpty, start > 0,
               let presentation = snapshot.stationPresentationContainingCaret(storagePosition: start - 1) {
                return store.document.tokens.first { $0.id == presentation.token.id }
            }
            return nil
        }

        private static func isStrongStationPrefix(query: String, stationName: String) -> Bool {
            let normalizedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let normalizedStation = stationName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return normalizedStation.hasPrefix(normalizedQuery)
        }

        private static func uniqueStrongStationMatch(for query: String, role: StationRole) -> String? {
            let candidates = StationSearchIndex.shared.matches(for: query, role: role, limit: 2)
            guard candidates.count == 1 else { return nil }
            let only = candidates[0]
            guard isStrongStationPrefix(query: query, stationName: only) else { return nil }
            return only
        }

        /// Space accepts: full typed match to the resolved name, or a single strong-prefix DB hit.
        private static func commitStationValueIfUniqueMatch(token: InlineToken) -> CheatValue? {
            guard case .station(let role, let currentName) = token.value else { return nil }
            let typed = token.matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, typed.caseInsensitiveCompare(currentName) == .orderedSame {
                Self.logger.debug("commitStationValueIfUniqueMatch accepted exact match typed='\(typed, privacy: .public)'")
                return .station(role: role, name: currentName)
            }
            let query = typed.isEmpty ? currentName : typed
            guard let match = uniqueStrongStationMatch(for: query, role: role) else { return nil }
            Self.logger.debug("commitStationValueIfUniqueMatch accepted unique strong prefix query='\(query, privacy: .public)' match='\(match, privacy: .public)'")
            return .station(role: role, name: match)
        }

        /// Second space after text that already ends with whitespace: accept top search hit (current prediction).
        private static func shouldCommitStationOnDoubleSpace(token: InlineToken, logicalCaret: Int) -> Bool {
            guard case .station = token.value else { return false }
            let r = token.plainRange
            guard logicalCaret == NSMaxRange(r) else { return false }
            return token.matchedText.last?.isWhitespace == true
        }

        private static func commitStationWithBestPrediction(token: InlineToken) -> CheatValue? {
            guard case .station(let role, let currentName) = token.value else { return nil }
            let raw = token.matchedText
            guard let firstNonSpace = raw.firstIndex(where: { !$0.isWhitespace }) else {
                return .station(role: role, name: currentName)
            }
            let afterLeading = String(raw[firstNonSpace...])
            let query = afterLeading.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                return .station(role: role, name: currentName)
            }
            let normalizedQuery = query
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .joined(separator: " ")
            guard !normalizedQuery.isEmpty else { return .station(role: role, name: currentName) }
            let matches = StationSearchIndex.shared.matches(for: normalizedQuery, role: role, limit: 1)
            if let best = matches.first {
                Self.logger.debug("commitStationWithBestPrediction query='\(normalizedQuery, privacy: .public)' best='\(best, privacy: .public)'")
                return .station(role: role, name: best)
            }
            Self.logger.debug("commitStationWithBestPrediction fallback currentName='\(currentName, privacy: .public)'")
            return .station(role: role, name: currentName)
        }

        private static func shouldExitAcceptedStationOnTypedCharacter(
            token: InlineToken,
            logicalCaret: Int,
            replacement: String
        ) -> Bool {
            guard logicalCaret == token.plainRange.upperBound else { return false }
            guard !replacement.isEmpty, replacement != "\n" else { return false }
            guard case .station(_, let currentName) = token.value else { return false }

            let typed = token.matchedText
            guard typed == typed.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return typed.caseInsensitiveCompare(currentName) == .orderedSame
        }

        private func commitStationExitInsertingSpaceAfter(
            stationToken: InlineToken,
            value: CheatValue,
            storageRange: NSRange,
            inlineTextView: InlineTokenTextView
        ) {
            let store = parent.store
            store.updateTokenValue(id: stationToken.id, value: value)
            if let updated = store.document.tokens.first(where: { $0.id == stationToken.id }) {
                let insertAt = updated.plainRange.upperBound
                store.applyEdit(
                    plainRange: NSRange(location: insertAt, length: 0),
                    replacementText: " "
                )
            }
            store.clearLogicalCaretPlainPosition()
            refreshEditor(animated: false, fallbackCaret: storageRange.location + 1)
            inlineTextView.typingAttributes = defaultTypingAttributes
            inlineTextView.syncSystemCaretVisibility()
        }

        private func commitStationExitKeepingCaretOutside(
            stationToken: InlineToken,
            value: CheatValue,
            inlineTextView: InlineTokenTextView
        ) {
            guard let textView else { return }
            let store = parent.store
            let metrics = parent.metrics

            store.updateTokenValue(id: stationToken.id, value: value)
            store.clearPendingCaretPlainPosition()
            store.clearLogicalCaretPlainPosition()
            store.buildSnapshot(metrics: metrics)

            let signature = store.renderSignature(metrics: metrics)
            textView.apply(
                snapshot: store.snapshot,
                metrics: metrics,
                animated: false,
                renderSignature: signature
            )
            textView.typingAttributes = defaultTypingAttributes

            let outsideCaret =
                store.snapshot.presentation(for: stationToken.id).map { $0.storageLocation + $0.storageLength } ??
                store.snapshot.caretStoragePosition ??
                textView.attributedText.length

            let safeCaret = min(outsideCaret, textView.attributedText.length)
            let expected = programmaticSelectionNeighborhood(
                around: safeCaret,
                maxLength: textView.attributedText.length
            )
            withProgrammaticSelection(expectedLocations: expected) {
                textView.selectedRange = NSRange(location: safeCaret, length: 0)
            }
            lastSelectionLocation = safeCaret
            textView.syncSystemCaretVisibility()
        }

        private func refreshEditor(animated: Bool, fallbackCaret: Int) {
            guard let textView = textView else { return }
            let store = parent.store
            let metrics = parent.metrics

            store.buildSnapshot(metrics: metrics)
            let signature = store.renderSignature(metrics: metrics)
            Self.logger.debug(
                "refreshEditor animated=\(animated, privacy: .public) fallbackCaret=\(fallbackCaret, privacy: .public) snapshotCaret=\(store.snapshot.caretStoragePosition ?? -1, privacy: .public)"
            )

            textView.apply(
                snapshot: store.snapshot,
                metrics: metrics,
                animated: animated,
                renderSignature: signature
            )
            textView.typingAttributes = defaultTypingAttributes

            if let caretPos = store.snapshot.caretStoragePosition {
                let safeCaret = min(caretPos, textView.attributedText.length)
                let expected = programmaticSelectionNeighborhood(
                    around: safeCaret,
                    maxLength: textView.attributedText.length
                )
                withProgrammaticSelection(expectedLocations: expected) {
                    textView.selectedRange = NSRange(location: safeCaret, length: 0)
                }
            } else {
                let safeCaret = min(fallbackCaret, textView.attributedText.length)
                let expected = programmaticSelectionNeighborhood(
                    around: safeCaret,
                    maxLength: textView.attributedText.length
                )
                withProgrammaticSelection(expectedLocations: expected) {
                    textView.selectedRange = NSRange(location: safeCaret, length: 0)
                }
            }
            textView.syncSystemCaretVisibility()
        }

        func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            let flexible = UIBarButtonItem(
                barButtonSystemItem: .flexibleSpace,
                target: nil,
                action: nil
            )
            let done = UIBarButtonItem(
                title: "Done",
                style: .prominent,
                target: self,
                action: #selector(dismissKeyboard)
            )

            toolbar.items = [flexible, done]
            return toolbar
        }

        @objc
        func dismissKeyboard() {
            textView?.resignFirstResponder()
        }
    }
}

// MARK: - Inline Text View

protocol InlineTokenTextViewDelegate: AnyObject {
    func inlineTokenViewDidRequestUpdate(id: UUID, value: CheatValue)
    func inlineTokenViewDidRequestRemove(id: UUID)
}

final class InlineTokenTextView: UITextView {
    weak var inlineDelegate: InlineTokenTextViewDelegate?

    fileprivate var currentRenderSignature: String?
    private var currentSnapshot: RenderedEditorSnapshot = .empty
    private var currentMetrics: LayoutMetrics?
    private var tokenViews: [UUID: InlineTokenControlView] = [:]
    private var shouldHideSystemCaret = false

    private lazy var tokenLongPressBlocker: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTokenLongPressBlocker(_:)))
        gesture.minimumPressDuration = 0.18
        // Must not cancel or delay touches to token subviews (e.g. stepper UIControl hold-to-repeat).
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delegate = self
        return gesture
    }()

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if tokenLongPressBlocker.view == nil {
            addGestureRecognizer(tokenLongPressBlocker)
        }
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)

        if gestureRecognizer is UILongPressGestureRecognizer, gestureRecognizer !== tokenLongPressBlocker {
            gestureRecognizer.isEnabled = false
        }
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        shouldHideSystemCaret ? .zero : super.caretRect(for: position)
    }

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let forced = forcedTrailingStationExitPosition(for: point) {
            return forced
        }
        return super.closestPosition(to: point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for tokenView in tokenViews.values.sorted(by: { $0.frame.maxX > $1.frame.maxX }) {
            guard tokenView.frame.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            let tokenPoint = convert(point, to: tokenView)
            if let hit = tokenView.hitTest(tokenPoint, with: event) {
                return hit
            }
            return tokenView
        }

        return super.hitTest(point, with: event)
    }

    private func forcedTrailingStationExitPosition(for point: CGPoint) -> UITextPosition? {
        for presentation in currentSnapshot.presentations where presentation.token.kind == .station {
            guard let tokenView = tokenViews[presentation.token.id] else { continue }

            let trailingExitZone = CGRect(
                x: tokenView.frame.maxX - 6,
                y: tokenView.frame.minY - 10,
                width: 28,
                height: tokenView.frame.height + 20
            )

            guard trailingExitZone.contains(point) else { continue }
            let storageOffset = presentation.storageLocation + presentation.storageLength
            return position(from: beginningOfDocument, offset: storageOffset)
        }
        return nil
    }

    func syncSystemCaretVisibility() {
        shouldHideSystemCaret = false
        tintColor = .systemBlue
        setNeedsDisplay()
    }

    @objc
    private func handleTokenLongPressBlocker(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            // Intentionally swallow long press over token zones.
        }
    }

    func apply(
        snapshot: RenderedEditorSnapshot,
        metrics: LayoutMetrics,
        animated: Bool,
        renderSignature: String
    ) {
        currentSnapshot = snapshot
        currentMetrics = metrics
        currentRenderSignature = renderSignature
        let savedDelegate = delegate
        delegate = nil
        attributedText = snapshot.attributedText
        delegate = savedDelegate
        syncInlineViews(animated: animated)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineViews(animated: false)
        bringInlineTokenViewsBehindTextContent()
    }

    /// Keeps chip overlays under the text engine’s layer so the insertion caret draws above the badge.
    private func bringInlineTokenViewsBehindTextContent() {
        for view in tokenViews.values {
            sendTokenViewBehindTextContent(view)
        }
    }

    private func sendTokenViewBehindTextContent(_ view: UIView) {
        sendSubviewToBack(view)
    }

    func dimUnfocusedInlineViews() {
        let caretLocation = selectedRange.location
        for presentation in currentSnapshot.presentations {
            guard let view = tokenViews[presentation.token.id] else { continue }
            let endInclusive = presentation.storageLocation + presentation.storageLength
            let isNearCaret = caretLocation >= presentation.storageLocation && caretLocation <= endInclusive
            view.setFocus(isNearCaret || isFirstResponder == false, animated: false)
        }
    }

    private func syncInlineViews(animated: Bool) {
        let newIDs = Set(currentSnapshot.presentations.map { $0.token.id })
        let oldIDs = Set(tokenViews.keys)

        let removedIDs = oldIDs.subtracting(newIDs)
        for id in removedIDs {
            guard let view = tokenViews.removeValue(forKey: id) else { continue }
            UIView.animate(withDuration: 0.16, animations: {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            }, completion: { _ in
                view.removeFromSuperview()
            })
        }

        for presentation in currentSnapshot.presentations {
            if let existing = tokenViews[presentation.token.id] {
                existing.update(token: presentation.token, metrics: currentMetrics!, animated: animated)
                existing.applyStationCaretPresentation(leadingTextWidth: nil)
            } else {
                let newView = InlineTokenControlFactory.makeView(
                    token: presentation.token,
                    metrics: currentMetrics!,
                    onUpdate: { [weak self] id, value in
                        self?.inlineDelegate?.inlineTokenViewDidRequestUpdate(id: id, value: value)
                    },
                    onRemove: { [weak self] id in
                        self?.inlineDelegate?.inlineTokenViewDidRequestRemove(id: id)
                    }
                )
                tokenViews[presentation.token.id] = newView
                addSubview(newView)
                sendTokenViewBehindTextContent(newView)
                newView.applyStationCaretPresentation(leadingTextWidth: nil)

                if animated {
                    newView.alpha = 0
                    newView.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
                        .concatenating(.init(translationX: 0, y: 8))
                }
            }
        }

        layoutInlineViews(animated: animated)
        bringInlineTokenViewsBehindTextContent()

        if animated {
            for presentation in currentSnapshot.presentations {
                guard let view = tokenViews[presentation.token.id], view.alpha < 1 else { continue }
                UIView.animate(
                    withDuration: 0.42,
                    delay: 0,
                    usingSpringWithDamping: 0.76,
                    initialSpringVelocity: 0.16,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    view.alpha = 1
                    view.transform = .identity
                }
            }
        }
    }

    private func layoutInlineViews(animated: Bool) {
        for presentation in currentSnapshot.presentations {
            guard let view = tokenViews[presentation.token.id] else { continue }

            let charRange = NSRange(location: presentation.storageLocation, length: presentation.storageLength)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }

            let glyphIndex = glyphRange.location

            var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            glyphRect.origin.x += textContainerInset.left
            glyphRect.origin.y += textContainerInset.top

            var lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.x += textContainerInset.left
            lineRect.origin.y += textContainerInset.top

            let size = presentation.size
            let nudgeY = currentMetrics?.inlineTokenVerticalNudge ?? 2.5
            let targetFrame = CGRect(
                x: glyphRect.origin.x,
                y: lineRect.midY - size.height / 2 + nudgeY,
                width: size.width,
                height: size.height
            ).integral

            if animated {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.84,
                    initialSpringVelocity: 0.12,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    view.frame = targetFrame
                }
            } else {
                view.frame = targetFrame
            }
        }
    }
}

extension InlineTokenTextView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tokenLongPressBlocker else { return true }
        let point = gestureRecognizer.location(in: self)
        return tokenViews.values.contains { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }
    }
}
