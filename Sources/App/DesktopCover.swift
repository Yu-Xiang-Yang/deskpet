import AppKit

/// A picture laid over the system wallpaper on every screen, just above it and below the desktop icons and
/// widgets. macOS shows the system wallpaper on the lock screen; with the cover, the lock screen can show one
/// picture (the system wallpaper) and the desktop another (the cover).
///
/// Pictures live in ~/Library/Application Support/DeskPet/cover/, one per display named by the display's UUID
/// (`<UUID>.png` or `.jpg`), with `default.png` / `default.jpg` for any other display.
@MainActor
final class DesktopCover {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?

    static var folder: URL { AppPaths.ensure(AppPaths.dataDir.appendingPathComponent("cover", isDirectory: true)) }

    var isShown: Bool { !windows.isEmpty }

    func setEnabled(_ on: Bool) {
        if on { show() } else { hide() }
    }

    func show() {
        hide()
        for screen in NSScreen.screens {
            guard let image = Self.image(for: screen) else { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Just above the wallpaper (the Dock draws it one level lower), below the icons and widgets.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            w.backgroundColor = .black
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.masksToBounds = true
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.isShown { self.show() } }
            }
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// The picture for `screen`: the one named after its display UUID, else the default one.
    static func image(for screen: NSScreen) -> NSImage? {
        var names: [String] = []
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            names.append(CFUUIDCreateString(nil, uuid) as String)
        }
        names.append("default")
        for name in names {
            for ext in ["png", "jpg", "jpeg", "heic"] {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }

    /// Asks for a picture and uses it for every display (replacing the per-display ones).
    static func choosePicture() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.message = tr("选择桌面上显示的图片（锁屏仍显示系统墙纸）", "Choose the picture for the desktop (the lock screen keeps the system wallpaper)")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return false }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: file) }
        try? fm.copyItem(at: source, to: folder.appendingPathComponent("default.\(source.pathExtension.lowercased())"))
        return true
    }
}
