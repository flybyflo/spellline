import Observation
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
            uiView.selectedRange = NSRange(location: safeCaret, length: 0)
        } else {
            let maxLocation = min(selectedRange.location, uiView.attributedText.length)
            let maxLength = min(selectedRange.length, max(0, uiView.attributedText.length - maxLocation))
            uiView.selectedRange = NSRange(location: maxLocation, length: maxLength)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InlineTokenTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(metrics.editorMinHeight, fitting.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, InlineTokenTextViewDelegate {
        var parent: InlinePromptEditor
        weak var textView: InlineTokenTextView?

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

            if replacement.isEmpty,
               storageRange.length == 1,
               let tokenID = snapshot.tokenHits[storageRange.location] {
                store.removeToken(id: tokenID)
                refreshEditor(animated: true, fallbackCaret: storageRange.location)
                return false
            }

            let plainRange = snapshot.mapStorageRangeToPlain(storageRange)
            store.applyEdit(plainRange: plainRange, replacementText: replacement)
            refreshEditor(animated: true, fallbackCaret: storageRange.location + (replacement as NSString).length)

            inlineTextView.typingAttributes = defaultTypingAttributes
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let inlineTextView = textView as? InlineTokenTextView else { return }
            inlineTextView.dimUnfocusedInlineViews()
        }

        func inlineTokenViewDidRequestUpdate(id: UUID, value: CheatValue) {
            parent.store.updateTokenValue(id: id, value: value)
            refreshEditor(animated: true, fallbackCaret: parent.store.snapshot.caretStoragePosition ?? 0)
        }

        func inlineTokenViewDidRequestRemove(id: UUID) {
            parent.store.removeToken(id: id)
            refreshEditor(animated: true, fallbackCaret: parent.store.snapshot.caretStoragePosition ?? 0)
        }

        private func refreshEditor(animated: Bool, fallbackCaret: Int) {
            guard let textView = textView else { return }
            let store = parent.store
            let metrics = parent.metrics

            store.buildSnapshot(metrics: metrics)
            let signature = store.renderSignature(metrics: metrics)

            textView.apply(
                snapshot: store.snapshot,
                metrics: metrics,
                animated: animated,
                renderSignature: signature
            )
            textView.typingAttributes = defaultTypingAttributes

            if let caretPos = store.snapshot.caretStoragePosition {
                let safeCaret = min(caretPos, textView.attributedText.length)
                textView.selectedRange = NSRange(location: safeCaret, length: 0)
            } else {
                let safeCaret = min(fallbackCaret, textView.attributedText.length)
                textView.selectedRange = NSRange(location: safeCaret, length: 0)
            }
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
        attributedText = snapshot.attributedText
        syncInlineViews(animated: animated)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineViews(animated: false)
    }

    func dimUnfocusedInlineViews() {
        let caretLocation = selectedRange.location
        for presentation in currentSnapshot.presentations {
            guard let view = tokenViews[presentation.token.id] else { continue }
            let isNearCaret = presentation.storageLocation == caretLocation || presentation.storageLocation + 1 == caretLocation
            view.setFocus(isNearCaret || isFirstResponder == false, animated: true)
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

                if animated {
                    newView.alpha = 0
                    newView.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
                        .concatenating(.init(translationX: 0, y: 8))
                }
            }
        }

        layoutInlineViews(animated: animated)

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

            let charRange = NSRange(location: presentation.storageLocation, length: 1)
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
