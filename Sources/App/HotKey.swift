import AppKit
import Carbon.HIToolbox

/// Global shortcuts for summoning the chat box. Carbon hot keys need no Accessibility permission.
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, shiftOptionSpace, commandShiftSpace, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .shiftOptionSpace: return "⇧⌥ Space"
        case .commandShiftSpace: return "⇧⌘ Space"
        case .off: return tr("关闭", "Off")
        }
    }

    /// Carbon modifier mask; nil when disabled.
    var modifiers: UInt32? {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .shiftOptionSpace: return UInt32(shiftKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .off: return nil
        }
    }
}

final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit { unregister() }

    /// Registers the preset; returns false when the system refuses it (e.g. already taken).
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let modifiers = preset.modifiers else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4450_4554), id: 1)  // "DPET"
        return RegisterEventHotKey(UInt32(kVK_Space), modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
