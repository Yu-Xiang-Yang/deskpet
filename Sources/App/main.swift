import AppKit

MainActor.assumeIsolated {
    guard SingleInstance.claim() else { exit(0) }
    LegacyDefaults.migrate()
    LoginItem.repairLocation()
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
