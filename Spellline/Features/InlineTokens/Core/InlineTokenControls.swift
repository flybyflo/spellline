import Combine
import SwiftUI
import UIKit

// MARK: - Liquid Glass helpers
//
// Interactive Liquid Glass is driven by `UIGlassEffect.isInteractive` on `UIVisualEffectView` (see Apple’s UIGlassEffect.h
// and WWDC 2025). SwiftUI’s `.glassEffect(.interactive())` inside `UIHostingController` does not reliably receive touches,
// so chrome uses UIKit glass here. See also: Stack Overflow “glassEffect regular interactive UIKit equivalent”.

private enum LiquidGlassUIKitShape {
    case capsule
    case circle
    case uniformFixedRadius(CGFloat)
}

private final class LiquidGlassUIKitGlassView: UIView {
    private let effectView: UIVisualEffectView
    private let glassEffect: UIGlassEffect
    private let tintAlpha: CGFloat
    private let shape: LiquidGlassUIKitShape

    /// Host controls or labels here so touches route through the glass (required for `isInteractive`).
    var glassContentView: UIView { effectView.contentView }

    init(shape: LiquidGlassUIKitShape, interactive: Bool, tintAlpha: CGFloat) {
        self.shape = shape
        self.tintAlpha = tintAlpha
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = interactive
        glassEffect = effect
        effectView = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        isUserInteractionEnabled = interactive
        backgroundColor = .clear
        clipsToBounds = true
        effectView.clipsToBounds = true
        addSubview(effectView)

        switch shape {
        case .capsule:
            effectView.cornerConfiguration = .capsule()
        case .circle:
            effectView.cornerConfiguration = .uniformCorners(radius: UICornerRadius.fixed(1))
        case .uniformFixedRadius(let r):
            effectView.cornerConfiguration = .uniformCorners(radius: UICornerRadius.fixed(r))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
        if case .circle = shape {
            let r = min(bounds.width, bounds.height) / 2
            effectView.cornerConfiguration = .uniformCorners(radius: UICornerRadius.fixed(r))
        }
    }

    func updateTint(_ tint: UIColor) {
        glassEffect.tintColor = tint.withAlphaComponent(tintAlpha)
        effectView.effect = glassEffect
    }
}

private struct LiquidGlassRoundedCard: UIViewRepresentable {
    var tint: UIColor

    func makeUIView(context: Context) -> LiquidGlassUIKitGlassView {
        let v = LiquidGlassUIKitGlassView(
            shape: .uniformFixedRadius(18),
            interactive: false,
            tintAlpha: 0.22
        )
        v.updateTint(tint)
        return v
    }

    func updateUIView(_ uiView: LiquidGlassUIKitGlassView, context: Context) {
        uiView.updateTint(tint)
    }
}

// MARK: - Stepper ± (SwiftUI glass buttons in UIKit)

private enum InlineStepperGlassMetrics {
    /// Fixed diameter for + / − glass circles (points).
    static let circleDiameter: CGFloat = 26
    /// Horizontal inset from the badge outline to the stack (smaller = circles closer to left/right edge).
    static let badgeHorizontalInset: CGFloat = 3

    /// Bold ± SF Symbol size: slightly larger than inline badge text, capped so glyphs stay inside the circle.
    static func glyphPointSize(sideLength: CGFloat, metrics: LayoutMetrics) -> CGFloat {
        let target = metrics.inlineControlFontSize - 3.5
        return min(target, sideLength * 0.52)
    }
}

private struct StepperGlassIconButton: View {
    let systemName: String
    /// Token accent for the glyph (full strength).
    let accent: Color
    let sideLength: CGFloat
    /// Matches `InlineBadgeTypography` weight; size from `InlineStepperGlassMetrics.glyphPointSize`.
    let glyphPointSize: CGFloat

    /// Matches `LiquidGlassUIKitGlassView` / capsule: `tint.withAlphaComponent(0.22)`.
    private var badgeGlass: Glass {
        .regular.tint(accent.opacity(0.22)).interactive()
    }

    var body: some View {
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: glyphPointSize, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.glass(badgeGlass))
        .buttonBorderShape(.circle)
        .frame(width: sideLength, height: sideLength)
        .clipShape(Circle())
        .contentShape(Circle())
        .allowsHitTesting(false)
    }
}

/// Touch handling + accelerated repeat while pressed (SwiftUI glass stays visual-only via `allowsHitTesting(false)`).
private final class StepperRepeatTouchControl: UIControl {
    /// `true` when firing from hold-repeat (skip bounce); `false` for a normal tap.
    var onStep: (_ isRepeatBurst: Bool) -> Void

    private var holdWorkItem: DispatchWorkItem?
    private var repeatTimer: Timer?
    private var repeatTickIndex = 0
    private var didStartRepeating = false

    /// Delay before the first repeated step when holding (seconds).
    private let holdBeforeRepeat: TimeInterval = 0.42

    init(onStep: @escaping (_ isRepeatBurst: Bool) -> Void) {
        self.onStep = onStep
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Ease-out curve: quick ramp, then settles near `minInterval` (seconds between steps).
    private func intervalBeforeStep(_ stepIndex: Int) -> TimeInterval {
        let minInterval: TimeInterval = 0.032
        let maxInterval: TimeInterval = 0.29
        let t = Double(stepIndex)
        return minInterval + (maxInterval - minInterval) * exp(-0.32 * t)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        cancelRepeatState()
        didStartRepeating = false
        repeatTickIndex = 0
        let work = DispatchWorkItem { [weak self] in
            self?.startAcceleratedRepeating()
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdBeforeRepeat, execute: work)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let wasRepeating = didStartRepeating
        cancelRepeatState()
        guard let touch else { return }
        if !wasRepeating, point(inside: touch.location(in: self), with: event) {
            onStep(false)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelRepeatState()
    }

    private func cancelRepeatState() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func startAcceleratedRepeating() {
        guard isTracking else { return }
        didStartRepeating = true
        repeatTickIndex = 0
        scheduleNextRepeatFire()
    }

    private func scheduleNextRepeatFire() {
        repeatTimer?.invalidate()
        guard isTracking else { return }
        onStep(true)
        let step = repeatTickIndex
        repeatTickIndex += 1
        let delay = intervalBeforeStep(step)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scheduleNextRepeatFire()
        }
        if let t = repeatTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }
}

private final class GlassStepperGlyphHostingView: UIView {
    private let hostingController: UIHostingController<StepperGlassIconButton>
    private let repeatTouch: StepperRepeatTouchControl
    private let systemName: String
    private let sideLength: CGFloat
    private let glyphPointSize: CGFloat
    private let onStep: (Bool) -> Void

    init(systemName: String, sideLength: CGFloat, glyphPointSize: CGFloat, tint: UIColor, onStep: @escaping (Bool) -> Void) {
        let step = onStep
        self.systemName = systemName
        self.sideLength = sideLength
        self.glyphPointSize = glyphPointSize
        self.onStep = onStep
        let root = StepperGlassIconButton(
            systemName: systemName,
            accent: Color(uiColor: tint),
            sideLength: sideLength,
            glyphPointSize: glyphPointSize
        )
        hostingController = UIHostingController(rootView: root)
        repeatTouch = StepperRepeatTouchControl(onStep: { isRepeatBurst in
            step(isRepeatBurst)
        })
        super.init(frame: .zero)
        repeatTouch.accessibilityLabel = systemName == "plus" ? "Increase" : "Decrease"
        clipsToBounds = true
        backgroundColor = .clear
        hostingController.view.backgroundColor = .clear
        hostingController.safeAreaRegions = []
        hostingController.view.isOpaque = false
        hostingController.view.clipsToBounds = true
        hostingController.view.isUserInteractionEnabled = false
        addSubview(hostingController.view)
        addSubview(repeatTouch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: sideLength, height: sideLength)
    }

    func updateTint(_ tint: UIColor) {
        hostingController.rootView = StepperGlassIconButton(
            systemName: systemName,
            accent: Color(uiColor: tint),
            sideLength: sideLength,
            glyphPointSize: glyphPointSize
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = bounds.integral
        hostingController.view.frame = r
        repeatTouch.frame = r
    }
}


// MARK: - Real Inline Controls

enum InlineTokenControlFactory {
    static func makeView(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) -> InlineTokenControlView {
        switch token.kind {
        case .count, .timer, .numberWithUnit:
            return InlineStepperTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .background:
            return InlineSliderTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .preset:
            return InlinePresetTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .station:
            return InlineStationTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .size:
            return InlineSizeTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .status:
            return InlineStatusTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .tag:
            return InlineTagTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        case .clock:
            return InlineTimeWheelTokenView(
                token: token,
                metrics: metrics,
                onUpdate: onUpdate,
                onRemove: onRemove
            )
        }
    }
}

class InlineTokenControlView: UIView {
    var token: InlineToken
    let metrics: LayoutMetrics
    let onUpdate: (UUID, CheatValue) -> Void
    let onRemove: (UUID) -> Void

    private lazy var suppressLongPressGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleSuppressedLongPress(_:)))
        gesture.minimumPressDuration = 0.18
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        return gesture
    }()

    init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        self.token = token
        self.metrics = metrics
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        super.init(frame: .zero)
        isOpaque = false
        clipsToBounds = false
        isUserInteractionEnabled = true
        addGestureRecognizer(suppressLongPressGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        self.token = token
    }

    /// Station badges use this to position the in-badge caret; default is no-op.
    func applyStationCaretPresentation(leadingTextWidth: CGFloat?) {}

    func setFocus(_ focused: Bool, animated: Bool) {
        let alpha: CGFloat = focused ? 1 : 0.92
        let scale: CGFloat = focused ? 1 : 0.985
        let changes = {
            self.alpha = alpha
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    func bounce() {
        transform = .identity
        UIView.animate(withDuration: 0.10, animations: {
            self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: { _ in
            UIView.animate(
                withDuration: 0.26,
                delay: 0,
                usingSpringWithDamping: 0.55,
                initialSpringVelocity: 0.15,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.transform = .identity
            }
        })
    }

    func fadeTextChange(_ block: @escaping () -> Void) {
        UIView.transition(
            with: self,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: block
        )
    }

    @objc
    private func handleSuppressedLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            // Intentionally swallow long press so UITextView doesn’t surface selection preview UI over token slots.
        }
    }
}

private final class GlassCapsuleContainerView: UIView {
    private let glassHost: LiquidGlassUIKitGlassView
    private let interactiveGlass: Bool

    override init(frame: CGRect) {
        interactiveGlass = false
        glassHost = LiquidGlassUIKitGlassView(shape: .capsule, interactive: false, tintAlpha: 0.22)
        super.init(frame: frame)
        commonInit(clipsContent: true)
    }

    init(frame: CGRect, interactiveGlass: Bool, clipsContent: Bool = true) {
        self.interactiveGlass = interactiveGlass
        glassHost = LiquidGlassUIKitGlassView(shape: .capsule, interactive: interactiveGlass, tintAlpha: 0.22)
        super.init(frame: frame)
        commonInit(clipsContent: clipsContent)
    }

    convenience init(interactiveGlass: Bool) {
        self.init(frame: .zero, interactiveGlass: interactiveGlass, clipsContent: true)
    }

    private func commonInit(clipsContent: Bool) {
        backgroundColor = .clear
        clipsToBounds = clipsContent
        addSubview(glassHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassHost.frame = bounds
        layer.cornerRadius = bounds.height / 2
    }

    func updateGlass(tint: UIColor) {
        glassHost.updateTint(tint)
    }
}

private final class InlineStepperTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView(frame: .zero, interactiveGlass: false, clipsContent: true)
    private let stack = UIStackView()
    private let valueLabel = UILabel()
    private let sideLength: CGFloat
    private var minusGlyphHost: GlassStepperGlyphHostingView!
    private var plusGlyphHost: GlassStepperGlyphHostingView!

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        sideLength = InlineStepperGlassMetrics.circleDiameter
        let glyphPointSize = InlineStepperGlassMetrics.glyphPointSize(sideLength: sideLength, metrics: metrics)
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        capsule.layer.borderWidth = 1
        addSubview(capsule)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(stack)

        minusGlyphHost = GlassStepperGlyphHostingView(
            systemName: "minus",
            sideLength: sideLength,
            glyphPointSize: glyphPointSize,
            tint: token.uiTint,
            onStep: { [weak self] isRepeatBurst in self?.adjust(-1, skipBounce: isRepeatBurst) }
        )
        plusGlyphHost = GlassStepperGlyphHostingView(
            systemName: "plus",
            sideLength: sideLength,
            glyphPointSize: glyphPointSize,
            tint: token.uiTint,
            onStep: { [weak self] isRepeatBurst in self?.adjust(1, skipBounce: isRepeatBurst) }
        )

        minusGlyphHost.translatesAutoresizingMaskIntoConstraints = false
        plusGlyphHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            minusGlyphHost.widthAnchor.constraint(equalToConstant: sideLength),
            minusGlyphHost.heightAnchor.constraint(equalToConstant: sideLength),
            plusGlyphHost.widthAnchor.constraint(equalToConstant: sideLength),
            plusGlyphHost.heightAnchor.constraint(equalToConstant: sideLength)
        ])

        valueLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        valueLabel.textAlignment = .center
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(minusGlyphHost)
        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(plusGlyphHost)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: InlineStepperGlassMetrics.badgeHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -InlineStepperGlassMetrics.badgeHorizontalInset),
            stack.centerYAnchor.constraint(equalTo: capsule.centerYAnchor)
        ])

        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        minusGlyphHost.updateTint(token.uiTint)
        plusGlyphHost.updateTint(token.uiTint)
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.24).cgColor

        let nextText: String
        switch token.kind {
        case .count:
            nextText = token.intValue == 1 ? "1x" : "\(token.intValue)x"
        case .timer:
            nextText = "\(token.intValue)s"
        case .numberWithUnit:
            nextText = "\(token.intValue)°"
        default:
            nextText = token.label
        }

        let tint = token.uiTint

        if animated {
            fadeTextChange {
                self.valueLabel.text = nextText
                self.valueLabel.textColor = tint
            }
        } else {
            valueLabel.text = nextText
            valueLabel.textColor = tint
        }
    }

    private func adjust(_ direction: Int, skipBounce: Bool = false) {
        let nextValue: CheatValue
        switch token.kind {
        case .count:
            let next = max(1, min(12, token.intValue + direction))
            nextValue = .int(next)
        case .timer:
            let next = max(1, min(60, token.intValue + direction))
            nextValue = .seconds(next)
        case .numberWithUnit:
            let step = 5 * direction
            let next = max(0, min(360, token.intValue + step))
            nextValue = .angle(Double(next))
        default:
            return
        }

        if nextValue == token.value { return }

        if !skipBounce {
            bounce()
        }
        onUpdate(token.id, nextValue)
        InlineTokenHaptics.stepperValueChanged()
    }
}

private final class InlineSliderTokenView: InlineTokenControlView {
    private let glassView = LiquidGlassUIKitGlassView(shape: .capsule, interactive: false, tintAlpha: 0.22)
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private var previewValue: Float?
    private var lastHapticPercent: Int?
    /// Throttle Taptic feedback: the motor can’t keep up if we fire on every 1% while scrubbing fast.
    private var lastSliderHapticTime: CFTimeInterval = -1
    private static let sliderHapticMinInterval: CFTimeInterval = 0.14

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        layer.masksToBounds = true
        layer.borderWidth = 1
        addSubview(glassView)

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(commitSlider), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(slider)

        valueLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        valueLabel.textAlignment = .right
        addSubview(valueLabel)

        update(token: token, metrics: metrics, animated: false)
    }

    /// Room for the widest label (`100%`) in bold; must stay in sync with `InlineTokenSizing` `.background`.
    private static func percentLabelReservedWidth(metrics: LayoutMetrics) -> CGFloat {
        let font = InlineBadgeTypography.badgeFont(metrics: metrics)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let w = ("100%" as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).width
        return ceil(w) + 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        glassView.frame = bounds
        layer.cornerRadius = bounds.height / 2

        let content = bounds.insetBy(dx: 10, dy: 4)
        let gap: CGFloat = 8
        let valueWidth = Self.percentLabelReservedWidth(metrics: metrics)

        valueLabel.frame = CGRect(
            x: content.maxX - valueWidth,
            y: content.minY,
            width: valueWidth,
            height: content.height
        )

        slider.frame = CGRect(
            x: content.minX,
            y: content.minY,
            width: max(metrics.sliderWidth, valueLabel.frame.minX - content.minX - gap),
            height: content.height
        )
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        glassView.updateTint(token.uiTint)
        layer.borderColor = token.uiTint.withAlphaComponent(0.22).cgColor

        let tint = token.uiTint
        slider.minimumTrackTintColor = tint.withAlphaComponent(InlineSizeSegmentStyle.selectedFillAlpha)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(InlineSizeSegmentStyle.unselectedTitleAlpha)
        slider.thumbTintColor = tint.blendedTowardWhite(0.4)

        let amount = Float(token.doubleValue)
        if !slider.isTracking {
            slider.value = amount
            lastHapticPercent = Int(amount * 100)
            lastSliderHapticTime = -1
        }

        let labelText = "\(Int((previewValue ?? amount) * 100))%"
        let labelTint = tint.withAlphaComponent(InlineSizeSegmentStyle.unselectedTitleAlpha)
        if animated {
            fadeTextChange {
                self.valueLabel.text = labelText
                self.valueLabel.textColor = labelTint
            }
        } else {
            valueLabel.text = labelText
            valueLabel.textColor = labelTint
        }
    }

    @objc
    private func sliderChanged() {
        previewValue = slider.value
        let p = Int(slider.value * 100)
        valueLabel.text = "\(p)%"
        if lastHapticPercent != p {
            lastHapticPercent = p
            let now = CACurrentMediaTime()
            let elapsed = lastSliderHapticTime < 0 ? .infinity : now - lastSliderHapticTime
            if elapsed >= Self.sliderHapticMinInterval {
                lastSliderHapticTime = now
                InlineTokenHaptics.sliderPercentTick()
            }
        }
    }

    @objc
    private func sliderTouchDown() {
        lastHapticPercent = Int(slider.value * 100)
        lastSliderHapticTime = -1
        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.08,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = 0.98
            self.transform = CGAffineTransform(scaleX: 1.01, y: 1.01)
        }
    }

    @objc
    private func commitSlider() {
        previewValue = nil

        UIView.animate(
            withDuration: 0.20,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.10,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = 1
            self.transform = .identity
        }

        lastHapticPercent = Int(slider.value * 100)
        lastSliderHapticTime = -1
        onUpdate(token.id, .percentage(Double(slider.value)))
    }
}

private final class InlinePresetTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let iconView = UIImageView()
    private let menuButton = UIButton(type: .system)

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)
        iconView.contentMode = .scaleAspectFit
        capsule.addSubview(iconView)
        capsule.addSubview(menuButton)

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.contentHorizontalAlignment = .left

        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        capsule.frame = bounds

        let inner = bounds.insetBy(dx: 8, dy: 4)
        let iconSide: CGFloat = 16
        let gap: CGFloat = 8

        iconView.frame = CGRect(
            x: inner.minX,
            y: inner.midY - iconSide / 2,
            width: iconSide,
            height: iconSide
        )

        menuButton.frame = CGRect(
            x: inner.minX + iconSide + gap,
            y: inner.minY,
            width: max(0, inner.maxX - inner.minX - iconSide - gap),
            height: inner.height
        )
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.22).cgColor

        iconView.image = UIImage(systemName: token.iconName)
        iconView.tintColor = token.uiTint

        let titleFont = InlineBadgeTypography.badgeFont(metrics: metrics)
        var config = UIButton.Configuration.plain()
        config.title = token.label
        config.image = nil
        config.baseForegroundColor = token.uiTint
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = titleFont
            return out
        }
        menuButton.configuration = config

        configureMenu()
    }

    private func configureMenu() {
        let actions = FilterPreset.allCases.map { preset -> UIAction in
            UIAction(
                title: preset.rawValue,
                state: currentPreset == preset ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.bounce()
                self.onUpdate(self.token.id, .preset(preset))
            }
        }

        menuButton.menu = UIMenu(
            title: "Filter preset",
            image: UIImage(systemName: "camera.filters"),
            options: [.singleSelection],
            children: actions
        )
    }

    private var currentPreset: FilterPreset {
        if case .preset(let preset) = token.value {
            return preset
        }
        return .ascii
    }
}

private final class InlineStationTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let iconView = UIImageView()
    private let menuButton = UIButton(type: .system)

    private let typedLabel = UILabel()
    private let typoLabel = UILabel()
    private let predictedLabel = UILabel()
    private let labelStack = UIStackView()
    /// Drawn at the logical caret position (system caret can’t sit inside the spacer glyph).
    private let caretLine = UIView()

    private var stationCaretLeadingTextWidth: CGFloat?

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)
        iconView.contentMode = .scaleAspectFit
        capsule.addSubview(iconView)
        capsule.addSubview(labelStack)
        capsule.addSubview(menuButton)
        capsule.addSubview(caretLine)

        caretLine.layer.cornerRadius = 1
        caretLine.layer.masksToBounds = true

        labelStack.axis = .horizontal
        labelStack.alignment = .center
        labelStack.spacing = 1
        labelStack.isUserInteractionEnabled = false

        labelStack.addArrangedSubview(typedLabel)
        labelStack.addArrangedSubview(typoLabel)
        labelStack.addArrangedSubview(predictedLabel)
        labelStack.setCustomSpacing(1, after: typoLabel)

        typedLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        typoLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        predictedLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)

        typedLabel.lineBreakMode = .byClipping
        typoLabel.lineBreakMode = .byClipping
        predictedLabel.lineBreakMode = .byTruncatingTail

        // Keep typed + typo from shrinking before ghost completion; equal default CR made `byClipping` hide leading glyphs.
        typedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        typoLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        predictedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        predictedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.contentHorizontalAlignment = .left
        menuButton.setTitleColor(.clear, for: .normal)
        menuButton.tintColor = .clear

        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds

        let inner = bounds.insetBy(dx: 8, dy: 4)
        let iconSide: CGFloat = 16
        let gap: CGFloat = 8

        iconView.frame = CGRect(
            x: inner.minX,
            y: inner.midY - iconSide / 2,
            width: iconSide,
            height: iconSide
        )

        menuButton.frame = CGRect(
            x: inner.minX + iconSide + gap,
            y: inner.minY,
            width: max(0, inner.maxX - inner.minX - iconSide - gap),
            height: inner.height
        )

        labelStack.frame = menuButton.frame

        layoutCaretLine(menuFrame: menuButton.frame)
    }

    private func layoutCaretLine(menuFrame: CGRect) {
        guard let leading = stationCaretLeadingTextWidth else {
            caretLine.isHidden = true
            return
        }
        caretLine.isHidden = false
        caretLine.backgroundColor = token.uiTint.withAlphaComponent(0.95)
        let w: CGFloat = 3
        let h = min(menuFrame.height * 0.92, max(16, metrics.inlineControlFontSize + 4))
        let x = menuFrame.minX + leading
        caretLine.frame = CGRect(x: x, y: menuFrame.midY - h / 2, width: w, height: h)
    }

    override func applyStationCaretPresentation(leadingTextWidth: CGFloat?) {
        stationCaretLeadingTextWidth = leadingTextWidth
        setNeedsLayout()
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.22).cgColor

        iconView.image = UIImage(systemName: token.iconName)
        iconView.tintColor = token.uiTint

        var config = UIButton.Configuration.plain()
        config.title = ""
        config.baseForegroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4)
        menuButton.configuration = config

        let display = stationDisplayParts()

        typedLabel.text = display.confirmed
        typedLabel.textColor = token.uiTint.withAlphaComponent(0.95)

        typoLabel.text = display.typos
        typoLabel.textColor = display.typos.isEmpty
            ? .clear
            : UIColor.systemRed.withAlphaComponent(0.95)

        predictedLabel.text = display.predicted
        predictedLabel.textColor = token.uiTint.withAlphaComponent(0.45)

        configureMenu()
    }

    private func configureMenu() {
        guard case .station(let role, _) = token.value else { return }

        menuButton.menu = UIMenu(
            title: role == .from ? "From station" : "To station",
            image: UIImage(systemName: token.iconName),
            children: [
                UIDeferredMenuElement { [weak self] completion in
                    completion(self?.stationMenuActions() ?? [])
                }
            ]
        )
    }

    private func stationMenuActions() -> [UIMenuElement] {
        guard case .station(let role, let currentName) = token.value else { return [] }

        let typed = token.matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = StationSearchIndex.shared.matches(
            for: typed.isEmpty ? currentName : typed,
            role: role,
            limit: 24
        )

        let options = candidates.isEmpty ? [currentName] : candidates

        return options.map { station in
            UIAction(
                title: station,
                state: station.caseInsensitiveCompare(currentName) == .orderedSame ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.bounce()
                self.onUpdate(self.token.id, .station(role: role, name: station))
            }
        }
    }

    private func stationDisplayParts() -> (confirmed: String, typos: String, predicted: String) {
        guard case .station(_, let resolved) = token.value else {
            return (token.label, "", "")
        }

        // Do not trim trailing spaces — a space after "amstetten" must stay in the badge or the caret looks wrong.
        let typed = token.matchedText.stationLeadingTrimmedWhitespace
        guard !typed.isEmpty else {
            return ("", "", resolved)
        }

        let foldedResolvedChars = Array(
            resolved.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        )
        let foldedTypedChars = Array(
            typed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        )

        var foldedPrefixLength = 0
        while foldedPrefixLength < min(foldedResolvedChars.count, foldedTypedChars.count),
              foldedResolvedChars[foldedPrefixLength] == foldedTypedChars[foldedPrefixLength] {
            foldedPrefixLength += 1
        }

        // Once the user has matched the full resolved station name (folded), extra keystrokes are not "typos"
        // vs prediction — e.g. trailing spaces before space-to-commit, or paste — show as normal confirmed text.
        if foldedPrefixLength >= foldedResolvedChars.count, !foldedResolvedChars.isEmpty {
            return (typed, "", "")
        }

        // `foldedPrefixLength` is in *folded* character space. Slicing `typed`/`resolved` by the same integer
        // is wrong when folding changes character count (case/diacritics/Unicode). Map n → original indices.
        let typedPrefixEnd = Self.originalIndex(afterFoldedPrefixLength: foldedPrefixLength, in: typed)
        let confirmedBase = String(typed[..<typedPrefixEnd])

        // After backspacing, spaces often sit in the "remainder" after the resolved prefix match.
        // If we put them in `typoLabel` (red), they are invisible but still take width → huge gap before the cursor.
        let remainder = String(typed[typedPrefixEnd...])
        let leadingSpaces = remainder.prefix(while: { $0.isWhitespace })
        let afterSpaces = remainder.dropFirst(leadingSpaces.count)
        let typos = String(afterSpaces.prefix(2))
        let confirmed = confirmedBase + leadingSpaces

        let resolvedSplit = Self.originalIndex(afterFoldedPrefixLength: foldedPrefixLength, in: resolved)
        let predicted = String(resolved[resolvedSplit...])

        return (confirmed, typos, predicted)
    }

    /// Smallest end index in `s` such that the folded form of `s[..<end]` has at least `n` folded characters
    /// matching the prefix of `s.folding(...)` (aligned with common-prefix logic in folded character arrays).
    private static func originalIndex(afterFoldedPrefixLength n: Int, in s: String) -> String.Index {
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
    /// Trims only leading whitespace so trailing spaces (e.g. after a word inside the station badge) stay visible.
    var stationLeadingTrimmedWhitespace: String {
        guard let i = firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[i...])
    }
}

/// Single source for inline badge character size and weight (steppers, tags, S/B segments, %, etc.).
private enum InlineBadgeTypography {
    static func badgeFont(metrics: LayoutMetrics) -> UIFont {
        metrics.inlineBadgeFont
    }
}

/// Inline control haptics. UIKit options (see Apple’s `UIFeedbackGenerator`):
/// - **`UIImpactFeedbackGenerator`**: physical “tap” — `.light` (subtle), `.medium`, `.heavy`, `.soft` (gentler, diffuse), `.rigid` (sharp, crisp).
/// - **`UISelectionFeedbackGenerator`**: small “click” when a selection moves (pickers, segments); use `selectionChanged()`.
/// - **`UINotificationFeedbackGenerator`**: outcome cues — `.success`, `.warning`, `.error` (usually not for continuous sliders).
/// - **Core Haptics** (`CHHapticEngine`): custom patterns when you need full control (more setup).
private enum InlineTokenHaptics {
    static func stepperValueChanged() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    /// Softer than the stepper’s light impact — better for frequent ticks while scrubbing.
    static func sliderPercentTick() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        g.impactOccurred()
    }

    static func segmentSelectionChanged() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
}

/// Shared accent opacity for size S/B segments and percent slider (tracks + label).
private enum InlineSizeSegmentStyle {
    /// Unselected S/B glyphs, % value label tint, and white max-track opacity (see slider).
    static let unselectedTitleAlpha: CGFloat = 0.7
    /// Selected S/B white glyph.
    static let selectedTitleAlpha: CGFloat = 0.9
    /// Selected segment pill and slider minimum (filled) track.
    static let selectedFillAlpha: CGFloat = 0.8

    /// Fixed width per segment (S at index 0, B at index 1). `nil` = automatic equal sizing.
    /// Use `0` for a single segment if you want that slot to stay automatic (per `UISegmentedControl` docs).
    static let segmentWidths: (s: CGFloat, b: CGFloat)? = nil
}

private struct InlineSizePresetSegmentPicker: View {
    @Binding var selection: SizePreset
    let tint: Color

    var body: some View {
        // Title color + font come from `UISegmentedControl.setTitleTextAttributes` so S and B match exactly.
        Picker("Size", selection: $selection) {
            Text("S").tag(SizePreset.smaller)
            Text("B").tag(SizePreset.bigger)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(tint)
        .accessibilityLabel("Size")
    }
}

private final class InlineSizeTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let hostingController: UIHostingController<InlineSizePresetSegmentPicker>

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        hostingController = UIHostingController(
            rootView: InlineSizePresetSegmentPicker(
                selection: .constant(.bigger),
                tint: .accentColor
            )
        )
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)
        hostingController.view.backgroundColor = .clear
        hostingController.safeAreaRegions = []
        hostingController.view.isOpaque = false
        capsule.addSubview(hostingController.view)
        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        let inner = bounds.insetBy(dx: -0.1, dy: 3).offsetBy(dx: 0, dy: -0.1)
        hostingController.view.frame = inner.integral
        applyProminentSegmentTitles()
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.4).cgColor
        refreshSegmentPicker()
    }

    private func refreshSegmentPicker() {
        hostingController.rootView = InlineSizePresetSegmentPicker(
            selection: sizePresetBinding(),
            tint: Color(uiColor: token.uiTint)
        )
        DispatchQueue.main.async { [weak self] in
            self?.applyProminentSegmentTitles()
        }
    }

    /// Segmented control defaults mute unselected titles; match other badges with full `uiTint` and bold label weight.
    private func applyProminentSegmentTitles() {
        guard let seg = firstSegmentedControl(in: hostingController.view) else { return }
        let tint = token.uiTint
        let font = InlineBadgeTypography.badgeFont(metrics: metrics)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: tint.withAlphaComponent(InlineSizeSegmentStyle.unselectedTitleAlpha),
            .font: font,
            .kern: 0
        ]
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white.withAlphaComponent(InlineSizeSegmentStyle.selectedTitleAlpha),
            .font: font,
            .kern: 0
        ]
        seg.setTitleTextAttributes(normalAttrs, for: .normal)
        seg.setTitleTextAttributes(selectedAttrs, for: .selected)
        seg.setTitleTextAttributes(normalAttrs, for: .highlighted)
        seg.setTitleTextAttributes(selectedAttrs, for: [.selected, .highlighted])
        seg.selectedSegmentTintColor = tint.withAlphaComponent(InlineSizeSegmentStyle.selectedFillAlpha)

        if let w = InlineSizeSegmentStyle.segmentWidths {
            seg.setWidth(w.s, forSegmentAt: 0)
            seg.setWidth(w.b, forSegmentAt: 1)
        }
    }

    private func firstSegmentedControl(in view: UIView) -> UISegmentedControl? {
        if let seg = view as? UISegmentedControl { return seg }
        for sub in view.subviews {
            if let found = firstSegmentedControl(in: sub) { return found }
        }
        return nil
    }

    private func sizePresetBinding() -> Binding<SizePreset> {
        Binding(
            get: { [weak self] in self?.currentPreset ?? .bigger },
            set: { [weak self] newValue in
                guard let self else { return }
                guard newValue != self.currentPreset else { return }
                self.bounce()
                self.onUpdate(self.token.id, .size(newValue))
                InlineTokenHaptics.segmentSelectionChanged()
            }
        )
    }

    private var currentPreset: SizePreset {
        if case .size(let preset) = token.value {
            return preset
        }
        return .bigger
    }
}

private final class InlineStatusTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)

        iconView.contentMode = .scaleAspectFit
        capsule.addSubview(iconView)

        label.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        label.lineBreakMode = .byTruncatingTail
        capsule.addSubview(label)

        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds

        let inner = bounds.insetBy(dx: 12, dy: 4)
        iconView.frame = CGRect(x: inner.minX, y: inner.midY - 8, width: 16, height: 16)
        label.frame = CGRect(
            x: iconView.frame.maxX + 8,
            y: inner.minY,
            width: max(0, inner.maxX - iconView.frame.maxX - 8),
            height: inner.height
        )
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.24).cgColor

        iconView.image = UIImage(systemName: token.iconName)
        iconView.tintColor = token.uiTint

        if animated {
            fadeTextChange {
                self.label.text = token.label
                self.label.textColor = .label
            }
        } else {
            label.text = token.label
            label.textColor = .label
        }
    }
}

private final class InlineTagTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)

        iconView.contentMode = .scaleAspectFit
        capsule.addSubview(iconView)

        label.font = InlineBadgeTypography.badgeFont(metrics: metrics)
        label.lineBreakMode = .byTruncatingTail
        capsule.addSubview(label)

        update(token: token, metrics: metrics, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds

        let inner = bounds.insetBy(dx: 12, dy: 4)
        iconView.frame = CGRect(x: inner.minX, y: inner.midY - 8, width: 16, height: 16)
        label.frame = CGRect(
            x: iconView.frame.maxX + 8,
            y: inner.minY,
            width: max(0, inner.maxX - iconView.frame.maxX - 8),
            height: inner.height
        )
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.24).cgColor

        iconView.image = UIImage(systemName: token.iconName)
        iconView.tintColor = token.uiTint

        if animated {
            fadeTextChange {
                self.label.text = token.label
                self.label.textColor = token.uiTint
            }
        } else {
            label.text = token.label
            label.textColor = token.uiTint
        }
    }
}

// MARK: - Clock wheel (SwiftUI inside inline badge)

private final class TimeWheelBridge: ObservableObject {
    @Published var hour: Int
    @Published var minute: Int
    @Published var isPM: Bool
    @Published var uiTint: UIColor

    let tokenID: UUID
    private let onUpdate: (UUID, CheatValue) -> Void
    private var lastEmitted: (Int, Int, Bool)
    private var isApplyingRemote = false

    init(token: InlineToken, onUpdate: @escaping (UUID, CheatValue) -> Void) {
        self.tokenID = token.id
        self.onUpdate = onUpdate
        self.uiTint = token.uiTint

        let initial: (Int, Int, Bool)
        if case .timeOfDay(let h, let m, let pm) = token.value {
            initial = (h, m, pm)
        } else {
            initial = (12, 0, false)
        }

        hour = initial.0
        minute = initial.1
        isPM = initial.2
        lastEmitted = initial
    }

    func syncFromToken(_ token: InlineToken) {
        guard case .timeOfDay(let h, let m, let pm) = token.value else { return }
        if h == hour, m == minute, pm == isPM { return }
        isApplyingRemote = true
        hour = h
        minute = m
        isPM = pm
        uiTint = token.uiTint
        lastEmitted = (h, m, pm)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingRemote = false
        }
    }

    func emitIfChanged() {
        guard !isApplyingRemote else { return }
        let next = (hour, minute, isPM)
        if next == lastEmitted { return }
        lastEmitted = next
        onUpdate(tokenID, .timeOfDay(hour12: hour, minute: minute, isPM: isPM))
    }
}

private final class TimeWheelPickerContainerView: UIView {
    let picker = UIDatePicker()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.minuteInterval = 1
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
    }
}

private struct NativeTimeWheelPicker: UIViewRepresentable {
    @ObservedObject var bridge: TimeWheelBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> TimeWheelPickerContainerView {
        let container = TimeWheelPickerContainerView()
        let picker = container.picker
        picker.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged), for: .valueChanged)
        context.coordinator.bridge = bridge
        return container
    }

    func updateUIView(_ container: TimeWheelPickerContainerView, context: Context) {
        context.coordinator.bridge = bridge
        let picker = container.picker
        picker.tintColor = bridge.uiTint
        let date = dateFromBridge(bridge)
        if abs(picker.date.timeIntervalSince(date)) > 0.5 {
            context.coordinator.isProgrammatic = true
            picker.setDate(date, animated: false)
            context.coordinator.isProgrammatic = false
        }
    }

    private func dateFromBridge(_ bridge: TimeWheelBridge) -> Date {
        var dc = DateComponents()
        dc.hour = hour24From12(bridge.hour, isPM: bridge.isPM)
        dc.minute = bridge.minute
        return Calendar.current.date(from: dc) ?? Date()
    }

    final class Coordinator: NSObject {
        var bridge: TimeWheelBridge
        var isProgrammatic = false

        init(bridge: TimeWheelBridge) {
            self.bridge = bridge
        }

        @objc
        func valueChanged(_ sender: UIDatePicker) {
            guard !isProgrammatic else { return }
            let cal = Calendar.current
            let h24 = cal.component(.hour, from: sender.date)
            let m = cal.component(.minute, from: sender.date)
            let (h12, pm) = hour12From24(h24)

            if bridge.hour != h12 || bridge.minute != m || bridge.isPM != pm {
                bridge.hour = h12
                bridge.minute = m
                bridge.isPM = pm
                bridge.emitIfChanged()
            }
        }
    }
}

private func hour12From24(_ h24: Int) -> (Int, Bool) {
    let isPM = h24 >= 12
    var h12 = h24 % 12
    if h12 == 0 { h12 = 12 }
    return (h12, isPM)
}

private func hour24From12(_ h12: Int, isPM: Bool) -> Int {
    if isPM {
        return h12 == 12 ? 12 : h12 + 12
    } else {
        return h12 == 12 ? 0 : h12
    }
}

private struct TimeWheelPopupCard: View {
    @ObservedObject var bridge: TimeWheelBridge
    let barWidth: CGFloat

    private let wheelHeight: CGFloat = 216
    private let cornerRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            NativeTimeWheelPicker(bridge: bridge)
                .frame(width: barWidth, height: wheelHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            LiquidGlassRoundedCard(tint: bridge.uiTint)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(uiColor: bridge.uiTint.withAlphaComponent(0.22)), lineWidth: 1)
        )
    }
}

private final class TimeWheelPopupOverlay: UIView {
    private static weak var current: TimeWheelPopupOverlay?

    private weak var sourceView: UIView?
    private let bridge: TimeWheelBridge
    private let metrics: LayoutMetrics
    private let dimmingView = UIView()
    private let cardView = UIView()
    private let hostingController: UIHostingController<TimeWheelPopupCard>

    static func present(from sourceView: UIView, bridge: TimeWheelBridge, metrics: LayoutMetrics) {
        current?.dismiss(animated: false)
        let overlay = TimeWheelPopupOverlay(sourceView: sourceView, bridge: bridge, metrics: metrics)
        current = overlay

        guard let window = sourceView.window else { return }
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        overlay.presentAnimated()
    }

    private init(sourceView: UIView, bridge: TimeWheelBridge, metrics: LayoutMetrics) {
        self.sourceView = sourceView
        self.bridge = bridge
        self.metrics = metrics
        hostingController = UIHostingController(
            rootView: TimeWheelPopupCard(bridge: bridge, barWidth: metrics.clockPickerBarWidth)
        )
        super.init(frame: .zero)

        backgroundColor = .clear

        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.06)
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissFromBackdrop))
        dimmingView.addGestureRecognizer(tap)

        hostingController.view.backgroundColor = .clear
        hostingController.safeAreaRegions = []

        cardView.backgroundColor = .clear
        cardView.clipsToBounds = true

        hostingController.view.clipsToBounds = true

        addSubview(dimmingView)
        addSubview(cardView)
        cardView.addSubview(hostingController.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimmingView.frame = bounds

        let cardW = metrics.clockPickerBarWidth + 20
        let cardH: CGFloat = 236

        guard let src = sourceView else { return }
        let anchor = src.convert(src.bounds, to: self)
        let safe = safeAreaInsets
        let gap: CGFloat = 8

        var x = anchor.minX
        x = max(safe.left + 8, min(x, bounds.width - safe.right - 8 - cardW))

        var y = anchor.maxY + gap
        if y + cardH > bounds.height - safe.bottom - 8 {
            y = anchor.minY - cardH - gap
        }
        y = max(safe.top + 8, min(y, bounds.height - safe.bottom - 8 - cardH))

        cardView.frame = CGRect(x: x, y: y, width: cardW, height: cardH)
        hostingController.view.frame = cardView.bounds
    }

    private func presentAnimated() {
        layoutIfNeeded()

        guard let src = sourceView else {
            alpha = 1
            return
        }

        let anchor = src.convert(src.bounds, to: self)
        let finalFrame = cardView.frame
        let startScaleX = max(0.78, anchor.width / max(finalFrame.width, 1))
        let startScaleY = max(0.24, anchor.height / max(finalFrame.height, 1))
        let translationX = anchor.midX - finalFrame.midX
        let translationY = anchor.midY - finalFrame.midY

        alpha = 0
        cardView.transform = CGAffineTransform(translationX: translationX, y: translationY)
            .scaledBy(x: startScaleX, y: startScaleY)

        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
        }

        UIView.animate(
            withDuration: 0.42,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.08,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.cardView.transform = .identity
        }
    }

    @objc
    private func dismissFromBackdrop() {
        dismiss(animated: true)
    }

    private func dismiss(animated: Bool) {
        let hide = {
            self.alpha = 0
            self.cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }

        let remove = {
            self.removeFromSuperview()
            if Self.current === self {
                Self.current = nil
            }
        }

        if animated {
            UIView.animate(withDuration: 0.18, animations: hide) { _ in remove() }
        } else {
            remove()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
}

private final class InlineTimeWheelTokenView: InlineTokenControlView {
    private let capsule = GlassCapsuleContainerView()
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let bridge: TimeWheelBridge

    override init(
        token: InlineToken,
        metrics: LayoutMetrics,
        onUpdate: @escaping (UUID, CheatValue) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        let b = TimeWheelBridge(token: token, onUpdate: onUpdate)
        bridge = b

        super.init(token: token, metrics: metrics, onUpdate: onUpdate, onRemove: onRemove)

        addSubview(capsule)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 4
        capsule.addSubview(stack)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural

        chevronView.contentMode = .scaleAspectFit
        chevronView.image = UIImage(systemName: "chevron.down")
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(chevronView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        update(token: token, metrics: metrics, animated: false)
    }

    @objc
    private func handleTap() {
        bounce()
        TimeWheelPopupOverlay.present(from: self, bridge: bridge, metrics: metrics)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        stack.frame = bounds.insetBy(dx: 12, dy: 4)

        chevronView.bounds.size = CGSize(width: 9, height: 9)
    }

    override func update(token: InlineToken, metrics: LayoutMetrics, animated: Bool) {
        super.update(token: token, metrics: metrics, animated: animated)

        bridge.syncFromToken(token)

        capsule.updateGlass(tint: token.uiTint)
        capsule.layer.borderWidth = 1
        capsule.layer.borderColor = token.uiTint.withAlphaComponent(0.22).cgColor

        chevronView.tintColor = token.uiTint

        titleLabel.font = InlineBadgeTypography.badgeFont(metrics: metrics)

        if animated {
            fadeTextChange {
                self.titleLabel.text = token.label
                self.titleLabel.textColor = token.uiTint
            }
        } else {
            titleLabel.text = token.label
            titleLabel.textColor = token.uiTint
        }
    }
}
