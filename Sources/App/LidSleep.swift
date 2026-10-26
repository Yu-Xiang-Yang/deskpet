import Foundation

/// Whether the Mac sleeps when its lid is closed. Ordinary power assertions (as `caffeinate` makes) only stop idle
/// sleep; closing the lid still sends a MacBook to sleep. The only switch for that is the system-wide
/// `pmset -a disablesleep`, which needs administrator rights, so each change goes through macOS's own
/// authorisation dialog (password or Touch ID). The display still turns off when the lid closes; networking and
/// running programs carry on. The setting stays as it is when DeskPet quits.
enum LidSleep {
    /// True when sleep is disabled (the Mac keeps running with the lid closed).
    static var staysAwake: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }) else { return false }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
    }

    /// On battery the Mac would keep draining (and warming up in a bag); the pet says so when this is turned on.
    static var onBattery: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("'Battery Power'")
    }

    /// Changes the setting through macOS's authorisation dialog (run off the main thread: the dialog waits for
    /// the owner). `done` receives the text for the pet to say.
    static func set(awake: Bool, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = awake ? tr("桌宠要让 Mac 合上盖子后继续运行（不休眠）。", "DeskPet wants the Mac to keep running with its lid closed.")
                               : tr("桌宠要恢复 Mac 合上盖子后休眠。", "DeskPet wants the Mac to sleep again when its lid is closed.")
            let source = "do shell script \"/usr/bin/pmset -a disablesleep \(awake ? 1 : 0)\" with prompt \"\(prompt)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let text: String
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                text = code == -128 ? tr("好的，没有更改合盖休眠设置。", "OK, the lid setting is unchanged.")
                                    : tr("更改失败：", "Couldn't change it: ") + (error[NSAppleScript.errorMessage] as? String ?? "\(code)")
            } else if awake {
                text = tr("好了：现在合上盖子 Mac 也会继续运行、保持联网，屏幕会关掉。", "Done: the Mac keeps running and online with the lid closed; the screen turns off.")
                    + (onBattery ? tr("现在用的是电池，合盖放进包里会持续耗电、发热，记得接电源或用完关掉。",
                                      " It is on battery now: in a bag it keeps draining and warms up, so plug in or turn this off afterwards.") : "")
            } else {
                text = tr("好了：合上盖子会正常休眠了。", "Done: closing the lid puts the Mac to sleep again.")
            }
            DispatchQueue.main.async { done(text) }
        }
    }
}
