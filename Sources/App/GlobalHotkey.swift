import Foundation
import AppKit
import Carbon.HIToolbox

/// Registers one system-wide shortcut via Carbon's RegisterEventHotKey —
/// still the only public API for global hotkeys that works regardless of
/// which app is frontmost. Fires on the main thread.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?
    private let hotkeyID: UInt32 = 1
    private static let fourCC: OSType = 0x44537161 // 'DSqa'

    var isRegistered: Bool { hotKeyRef != nil }

    /// Installs the handler once; call before/after register/unregister.
    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           UInt32(kEventParamDirectObject),
                                           UInt32(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            guard status == noErr else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            manager.handleHotKey(id: hkID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func handleHotKey(id: UInt32) {
        guard id == hotkeyID else { return }
        DispatchQueue.main.async { [handler] in
            handler?()
        }
    }

    /// Maps NSEvent modifier flags to Carbon modifier bits.
    static func carbonModifiers(from ns: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if ns.contains(.command) { flags |= UInt32(cmdKey) }
        if ns.contains(.option) { flags |= UInt32(optionKey) }
        if ns.contains(.control) { flags |= UInt32(controlKey) }
        if ns.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var modifiers = ""
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers += "⌘" }
        let glyph = keyGlyph(keyCode: keyCode) ?? "#\(keyCode)"
        return modifiers + glyph
    }

    /// ANSI virtual key codes → glyphs (values from HIToolbox/Events.h);
    /// enough coverage for shortcut recording. Anything exotic falls back
    /// to the raw code number.
    private static func keyGlyph(keyCode: UInt32) -> String? {
        let table: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9", 29: "0",
            27: "-", 24: "=", 30: "]", 33: "[", 39: "'", 41: ";", 43: ",",
            47: ".", 44: "/", 42: "\\", 50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc",
        ]
        return table[keyCode]
    }

    /// Registers `spec`, replacing any previous registration.
    func register(spec: AppSettings.HotkeySpec, handler: @escaping () -> Void) {
        unregister()
        installEventHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.fourCC, id: hotkeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode,
                                         spec.carbonModifiers,
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, ref != nil else { return }
        hotKeyRef = ref
        self.handler = handler
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        handler = nil
    }
}
