import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable, Sendable {
    case captureRegion
    case captureWindow
    case captureFullscreen
    case colorPicker
    case magnifier

    var label: String {
        switch self {
        case .captureRegion: return "Capture Region"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .colorPicker: return "Pick Color"
        case .magnifier: return "Magnifier"
        }
    }
}

extension HotkeySettings {
    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        switch action {
        case .captureRegion: return region
        case .captureWindow: return window
        case .captureFullscreen: return fullscreen
        case .colorPicker: return colorPicker
        case .magnifier: return magnifier
        }
    }

    mutating func setBinding(_ binding: HotkeyBinding?, for action: HotkeyAction) {
        switch action {
        case .captureRegion: region = binding
        case .captureWindow: window = binding
        case .captureFullscreen: fullscreen = binding
        case .colorPicker: colorPicker = binding
        case .magnifier: magnifier = binding
        }
    }

    /// Actions that share the same key combination (settings UI warns on these).
    func conflicts() -> [(HotkeyAction, HotkeyAction)] {
        var result: [(HotkeyAction, HotkeyAction)] = []
        let actions = HotkeyAction.allCases
        for (i, a) in actions.enumerated() {
            guard let bindingA = binding(for: a) else { continue }
            for b in actions.dropFirst(i + 1) {
                if binding(for: b) == bindingA {
                    result.append((a, b))
                }
            }
        }
        return result
    }
}

extension HotkeyBinding {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    @MainActor
    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    @MainActor
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key\(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer)
            .takeUnretainedValue() as Data
        let translated = layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return translated ?? "key\(keyCode)"
    }
}

/// System-wide hotkeys via Carbon RegisterEventHotKey (PRD §8.1). Unlike a
/// CGEventTap, this path needs no Accessibility permission.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Receives the action when its hotkey fires.
    var handler: ((HotkeyAction) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotkeyAction] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false
    private static let signature: OSType = 0x6D736874 // 'msht'

    /// (Re)register all bindings; returns actions whose registration failed
    /// (typically: combination already taken by another app).
    @discardableResult
    func apply(_ settings: HotkeySettings) -> [HotkeyAction] {
        installEventHandlerIfNeeded()
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        actions.removeAll()

        var failed: [HotkeyAction] = []
        for action in HotkeyAction.allCases {
            guard let binding = settings.binding(for: action) else { continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs[id] = ref
                actions[id] = action
            } else {
                failed.append(action)
                Log.error("Could not register hotkey for \(action.rawValue) (status \(status))")
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func dispatch(id: UInt32) {
        guard let action = actions[id] else { return }
        handler?(action)
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches hotkey events on the main thread.
            MainActor.assumeIsolated {
                manager.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        eventHandlerInstalled = true
    }
}
