import AppKit

/// A small card below the pet that asks the owner to allow one action ("Add to Calendar: …"). It does not take the
/// focus from the current app. Nobody answering within the time-out counts as a refusal, and so does a request
/// while the owner is away from the Mac.
final class ApprovalPanel: NSPanel {
    static let timeout: TimeInterval = 120

    private let label = NSTextField(wrappingLabelWithString: "")
    private let allow = NSButton(title: tr("允许", "Allow"), target: nil, action: nil)
    private let deny = NSButton(title: tr("拒绝", "Deny"), target: nil, action: nil)
    private var pending: [(text: String, done: (Bool) -> Void)] = []
    private var current: ((Bool) -> Void)?
    private var timer: Timer?
    private weak var anchor: NSWindow?

    override var canBecomeKey: Bool { true }  // a non-activating panel: the current app stays active
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 96))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(calibratedRed: 0.79, green: 0.64, blue: 0.36, alpha: 0.8).cgColor

        label.font = .systemFont(ofSize: 12.5)
        label.maximumNumberOfLines = 4
        allow.bezelStyle = .rounded
        allow.keyEquivalent = "\r"
        allow.target = self
        allow.action = #selector(allowed)
        deny.bezelStyle = .rounded
        deny.target = self
        deny.action = #selector(denied)

        for v in [label, allow, deny] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            allow.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            allow.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            deny.trailingAnchor.constraint(equalTo: allow.leadingAnchor, constant: -8),
            deny.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        contentView = background
    }

    /// Asks once; requests that arrive while one is open wait their turn. `done` receives the answer.
    func ask(_ text: String, below anchor: NSWindow, done: @escaping (Bool) -> Void) {
        guard PetBrain.idleSeconds < ReminderRules.awaySeconds else { done(false); return }
        self.anchor = anchor
        pending.append((text, done))
        if current == nil { showNext() }
    }

    private func showNext() {
        guard !pending.isEmpty, let anchor else { return }
        let next = pending.removeFirst()
        current = next.done
        label.stringValue = next.text
        let a = anchor.frame
        var origin = NSPoint(x: a.midX - frame.width / 2, y: a.minY - frame.height - 4)
        if let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = a.minY + 8 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        }
        setFrameOrigin(origin)
        if parent == nil { anchor.addChildWindow(self, ordered: .above) }
        orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in self?.answer(false) }
    }

    @objc private func allowed() { answer(true) }
    @objc private func denied() { answer(false) }

    private func answer(_ yes: Bool) {
        timer?.invalidate()
        timer = nil
        let done = current
        current = nil
        if pending.isEmpty {
            parent?.removeChildWindow(self)
            orderOut(nil)
        }
        done?(yes)
        showNext()
    }
}
