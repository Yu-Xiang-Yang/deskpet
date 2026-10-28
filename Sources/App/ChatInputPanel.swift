import AppKit

/// A small text field below the pet. It becomes key without activating the app, so typing does not
/// pull the user's current application to the background. Return sends, Escape or clicking elsewhere closes.
final class ChatInputPanel: NSPanel, NSTextFieldDelegate {
    private final class KeyPanelField: NSTextField {
        var onEscape: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }

    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// The app that was active before the shortcut activated this one.
    private var previousApp: NSRunningApplication?
    private let field = KeyPanelField()
    private let sendButton = NSButton()
    private let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(calibratedRed: 0.96, green: 0.56, blue: 0.77, alpha: 0.7).cgColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.onEscape = { [weak self] in self?.dismiss() }
        field.target = self
        field.action = #selector(submit)

        sendButton.bezelStyle = .inline
        sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.contentTintColor = NSColor(calibratedRed: 0.48, green: 0.35, blue: 0.88, alpha: 1)
        sendButton.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        sendButton.target = self
        sendButton.action = #selector(submit)

        for v in [field, sendButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            sendButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 26),
        ])
        contentView = background
    }

    /// Just below the character's paws (`feetY`, screen coordinates), centred under the pet window.
    func present(below anchor: NSWindow, feetY: CGFloat, placeholder: String, activating: Bool = false) {
        prepare(placeholder: placeholder, activating: activating, cinematic: false)
        let a = anchor.frame
        var origin = NSPoint(x: a.midX - frame.width / 2, y: feetY - frame.height - 4)
        if let screen = anchor.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                // No room below the pet (it usually stands on the Dock): overlap its lower edge instead.
                origin.y = feetY + 8
            }
            // Keep the whole box on screen when the pet sits at a screen edge.
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        setFrameOrigin(origin)
        if parent == nil { anchor.addChildWindow(self, ordered: .above) }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// In the desktop film: a wider box centred on `point` (screen coordinates), where the subtitles appear, in
    /// the film's dark and gold style.
    func present(centeredAt point: NSPoint, on screen: NSScreen, placeholder: String, activating: Bool) {
        prepare(placeholder: placeholder, activating: activating, cinematic: true)
        let visible = screen.visibleFrame
        var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        parent?.removeChildWindow(self)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    private func prepare(placeholder: String, activating: Bool, cinematic: Bool) {
        if activating, !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        field.placeholderString = placeholder
        setContentSize(NSSize(width: cinematic ? 460 : 300, height: 40))
        background.appearance = cinematic ? NSAppearance(named: .darkAqua) : nil
        background.material = cinematic ? .hudWindow : .popover
        background.layer?.borderColor = cinematic
            ? NSColor(calibratedRed: 0.84, green: 0.67, blue: 0.31, alpha: 0.85).cgColor
            : NSColor(calibratedRed: 0.96, green: 0.56, blue: 0.77, alpha: 0.7).cgColor
        sendButton.contentTintColor = cinematic
            ? NSColor(calibratedRed: 0.88, green: 0.72, blue: 0.38, alpha: 1)
            : NSColor(calibratedRed: 0.48, green: 0.35, blue: 0.88, alpha: 1)
    }

    /// Closes without handing focus back to the previous app (another window of this app takes over).
    func dismissKeepingFocus() {
        previousApp = nil
        dismiss()
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
        onClose?()
        if let app = previousApp {
            previousApp = nil
            app.activate()
        }
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        onSend?(text)
    }
}
