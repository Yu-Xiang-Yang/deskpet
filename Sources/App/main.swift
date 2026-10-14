import AppKit

MainActor.assumeIsolated {
    LegacyDefaults.migrate()
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
