import AppKit
import QuartzCore

@MainActor
final class DictionarySuggestionPromptController {
    private static let dismissDuration: TimeInterval = 15

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var progressLayer: CALayer?
    private var dismissDeadline: Date?
    private var remainingDismissDuration: TimeInterval = 0
    private var isDismissPaused = false

    func show(
        suggestion: DictionarySuggestion,
        anchorFrame: NSRect?,
        onAdd: @escaping () -> Void,
        onLater: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        dismiss()

        let cardWidth: CGFloat = 384
        let cardHeight: CGFloat = 74
        let closeButtonSize: CGFloat = 22
        let cardX = closeButtonSize / 2 + 1
        let topGutter: CGFloat = closeButtonSize / 2 + 1
        let size = NSSize(width: cardWidth + cardX, height: cardHeight + topGutter)
        let frame = Self.frame(for: size, anchorFrame: anchorFrame)
        let panel = DictionarySuggestionPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let contentView = DictionarySuggestionHoverView(frame: NSRect(origin: .zero, size: size))
        contentView.onMouseEntered = { [weak self] in self?.pauseDismissCountdown() }
        contentView.onMouseExited = { [weak self] in self?.resumeDismissCountdown() }
        contentView.wantsLayer = true

        let cardView = DictionarySuggestionPromptView(
            frame: NSRect(origin: .zero, size: size),
            cardFrame: NSRect(x: cardX, y: 0, width: cardWidth, height: cardHeight),
            suggestion: suggestion,
            onAdd: { [weak self] in
                self?.dismiss()
                onAdd()
            },
            onLater: { [weak self] in
                self?.dismiss()
                onLater()
            },
            onIgnore: { [weak self] in
                self?.dismiss()
                onIgnore()
            }
        )
        contentView.addSubview(cardView)

        let dismissButton = NSButton(title: "×", target: self, action: #selector(handleDismiss))
        dismissButton.font = .systemFont(ofSize: 15, weight: .medium)
        dismissButton.frame = NSRect(
            x: cardX - closeButtonSize / 2,
            y: cardHeight + topGutter - closeButtonSize,
            width: closeButtonSize,
            height: closeButtonSize
        )
        dismissButton.wantsLayer = true
        dismissButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        dismissButton.layer?.borderWidth = 1
        dismissButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        dismissButton.layer?.cornerRadius = closeButtonSize / 2
        dismissButton.alignment = .center
        dismissButton.focusRingType = .none
        dismissButton.isBordered = false
        dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        dismissButton.toolTip = "Dismiss"
        contentView.addSubview(dismissButton)

        let progressBar = CALayer()
        progressBar.frame = CGRect(x: 0, y: 0, width: cardWidth, height: 3)
        progressBar.backgroundColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.8).cgColor
        progressBar.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressBar.position = CGPoint(x: cardX, y: 1.5)
        contentView.layer?.addSublayer(progressBar)
        progressLayer = progressBar
        panel.contentView = contentView

        self.panel = panel
        panel.orderFrontRegardless()
        startDismissCountdown(duration: Self.dismissDuration)
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
        remainingDismissDuration = 0
        isDismissPaused = false
        progressLayer?.removeAllAnimations()
        progressLayer?.speed = 1
        progressLayer?.timeOffset = 0
        progressLayer?.beginTime = 0
        progressLayer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func startDismissCountdown(duration: TimeInterval) {
        remainingDismissDuration = duration
        isDismissPaused = false
        startProgressAnimation(duration: duration)
        scheduleDismissTimer(after: duration)
    }

    private func startProgressAnimation(duration: TimeInterval) {
        guard let progressLayer else { return }
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = progressLayer.bounds.width
        shrink.toValue = 0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        progressLayer.add(shrink, forKey: "countdown")
    }

    private func scheduleDismissTimer(after duration: TimeInterval) {
        dismissTimer?.invalidate()
        dismissDeadline = Date().addingTimeInterval(duration)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func pauseDismissCountdown() {
        guard !isDismissPaused else { return }
        isDismissPaused = true
        if let dismissDeadline {
            remainingDismissDuration = max(0.1, dismissDeadline.timeIntervalSinceNow)
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil

        guard let progressLayer else { return }
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
    }

    private func resumeDismissCountdown() {
        guard isDismissPaused else { return }
        isDismissPaused = false
        scheduleDismissTimer(after: remainingDismissDuration)

        guard let progressLayer else { return }
        let pausedTime = progressLayer.timeOffset
        let resumeHostTime = CACurrentMediaTime()
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = resumeHostTime - pausedTime
    }

    @objc private func handleDismiss() {
        dismiss()
    }

    private static func frame(for size: NSSize, anchorFrame: NSRect?) -> NSRect {
        let screenFrame = (anchorFrame.flatMap { anchor in
            NSScreen.screens.first { screen in
                screen.visibleFrame.intersects(anchor)
            }
        } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let anchor = anchorFrame ?? NSRect(
            x: screenFrame.midX - 22,
            y: screenFrame.minY + 24,
            width: 44,
            height: 28
        )

        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 10
        if y + size.height > screenFrame.maxY {
            y = anchor.minY - size.height - 10
        }
        x = min(max(x, screenFrame.minX + 12), screenFrame.maxX - size.width - 12)
        y = min(max(y, screenFrame.minY + 12), screenFrame.maxY - size.height - 12)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
private final class DictionarySuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DictionarySuggestionHoverView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

@MainActor
private final class DictionarySuggestionPromptView: NSView {
    private let cardFrame: NSRect
    private let suggestion: DictionarySuggestion
    private let onAdd: () -> Void
    private let onLater: () -> Void
    private let onIgnore: () -> Void

    init(
        frame: NSRect,
        cardFrame: NSRect,
        suggestion: DictionarySuggestion,
        onAdd: @escaping () -> Void,
        onLater: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        self.cardFrame = cardFrame
        self.suggestion = suggestion
        self.onAdd = onAdd
        self.onLater = onLater
        self.onIgnore = onIgnore
        super.init(frame: frame)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let cardView = NSView(frame: cardFrame)
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97).cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(cardView)

        let iconSize: CGFloat = 26
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "Dictionary")
            ?? NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Dictionary")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 14, y: (cardFrame.height - iconSize) / 2 + 1, width: iconSize, height: iconSize)
        cardView.addSubview(iconView)

        let textX: CGFloat = 49
        let buttonWidth: CGFloat = 68
        let buttonGap: CGFloat = 8
        let buttonY: CGFloat = 22
        let buttonHeight: CGFloat = 30
        let ignoreX = cardFrame.width - 12 - buttonWidth
        let laterX = ignoreX - buttonGap - buttonWidth
        let addX = laterX - buttonGap - buttonWidth
        let textMaxX = addX - 12

        let title = label("Add correction?", font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        title.frame = NSRect(x: textX, y: 41, width: max(40, textMaxX - textX), height: 18)
        cardView.addSubview(title)

        let detail = label(
            "\"\(truncate(suggestion.observed, limit: 22))\" -> \"\(truncate(suggestion.replacement, limit: 22))\"",
            font: .systemFont(ofSize: 11),
            color: NSColor.white.withAlphaComponent(0.58)
        )
        detail.frame = NSRect(x: textX, y: 22, width: max(40, textMaxX - textX), height: 16)
        cardView.addSubview(detail)

        let add = button(title: "Add", action: #selector(addTapped), isPrimary: true)
        add.frame = NSRect(x: addX, y: buttonY, width: buttonWidth, height: buttonHeight)
        cardView.addSubview(add)

        let later = button(title: "Later", action: #selector(laterTapped), isPrimary: false)
        later.frame = NSRect(x: laterX, y: buttonY, width: buttonWidth, height: buttonHeight)
        cardView.addSubview(later)

        let ignore = button(title: "Ignore", action: #selector(ignoreTapped), isPrimary: false)
        ignore.frame = NSRect(x: ignoreX, y: buttonY, width: buttonWidth, height: buttonHeight)
        cardView.addSubview(ignore)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func button(title: String, action: Selector, isPrimary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.wantsLayer = true
        button.layer?.backgroundColor = isPrimary
            ? NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.cornerRadius = 6
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = .white
        return button
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "..."
    }

    @objc private func addTapped() {
        onAdd()
    }

    @objc private func laterTapped() {
        onLater()
    }

    @objc private func ignoreTapped() {
        onIgnore()
    }
}
