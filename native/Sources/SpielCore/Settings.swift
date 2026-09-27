import Carbon.HIToolbox
import Foundation

/// How the dictation hotkey behaves. `toggle` is what every build before 2.4 did
/// (press to start, press again to stop — only the key-DOWN event was ever
/// handled); `hold` records while the key is held and stops on release.
public enum DictationMode: String, CaseIterable, Sendable {
    case toggle, hold
    public var label: String {
        switch self {
        case .toggle: return "Press to start, press again to stop"
        case .hold: return "Hold to talk, release to stop"
        }
    }
}

/// The engine the user asked for. The app tries it first and falls back through
/// the others, so a missing download degrades the engine, never the app.
public enum EngineChoice: String, CaseIterable, Sendable {
    case unified, v3, apple
    public var label: String {
        switch self {
        case .unified: return "Parakeet Unified EN (default, most accurate)"
        case .v3: return "Parakeet TDT v3 (multilingual)"
        case .apple: return "Apple SpeechAnalyzer (macOS 26+)"
        }
    }
    /// The name written into transcripts and diagnostics.
    public var engineName: String {
        switch self {
        case .unified: return "parakeet-unified-en-0.6b"
        case .v3: return "parakeet-tdt-0.6b-v3"
        case .apple: return "apple-speechanalyzer"
        }
    }
    /// Chosen engine first, then the rest in the default order.
    public static func fallbackOrder(_ choice: EngineChoice) -> [EngineChoice] {
        [choice] + allCases.filter { $0 != choice }
    }
}

/// Human names for Carbon virtual key codes, and the label a combo is shown as.
public enum KeyNames {
    static let table: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
    static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool { fKeys[Int(keyCode)] != nil }

    public static func name(_ keyCode: UInt32) -> String {
        fKeys[Int(keyCode)] ?? table[Int(keyCode)] ?? String(format: "Key 0x%02X", keyCode)
    }

    /// Modifier order matches the labels Spiel has always shown (⌘⇧D, ⌘⇧L).
    public static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        return s + name(keyCode)
    }

    /// Carbon modifier mask from the four flags (the app converts NSEvent flags).
    public static func carbonModifiers(command: Bool, shift: Bool, option: Bool, control: Bool) -> UInt32 {
        var m: UInt32 = 0
        if command { m |= UInt32(cmdKey) }
        if shift { m |= UInt32(shiftKey) }
        if option { m |= UInt32(optionKey) }
        if control { m |= UInt32(controlKey) }
        return m
    }
}

/// What a recorded shortcut must satisfy before Spiel tries to register it.
public enum HotkeyRules {
    /// ⌘ plus one of these would take the key away from EVERY app (a global hotkey
    /// wins over the focused app's menu), so ⌘Q would stop quitting anything.
    static let reservedWithCommandOnly: Set<Int> = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A,
        kVK_ANSI_S, kVK_Tab, kVK_Space,
    ]

    /// nil = acceptable; otherwise the sentence shown under the field.
    public static func validate(_ combo: HotkeyManager.Combo, otherCombo: HotkeyManager.Combo?, otherName: String) -> String? {
        let mods = combo.modifiers
        let strong = UInt32(cmdKey | optionKey | controlKey)
        if mods & strong == 0 && !KeyNames.isFunctionKey(combo.keyCode) {
            return mods == 0
                ? "\(combo.description) needs a modifier (⌘, ⌥ or ⌃) — only F-keys work on their own"
                : "\(combo.description) would fire while typing — add ⌘, ⌥ or ⌃"
        }
        if mods == UInt32(cmdKey) && reservedWithCommandOnly.contains(Int(combo.keyCode)) {
            return "\(combo.description) is a standard shortcut every app uses — pick another"
        }
        if let otherCombo, combo.sameKeys(as: otherCombo) {
            return "\(combo.description) is already the \(otherName) shortcut"
        }
        return nil
    }
}

/// Every persisted preference, in the one defaults domain the app and `spiel-cli`
/// share (see `DiagnosticLog.defaultsDomain`). Injectable so selftest round-trips
/// against a throwaway suite, never the real one.
public struct SpielSettings {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = DiagnosticLog.defaults) { self.defaults = defaults }

    public static let dictationHotkeyKey = "DictationHotkey"
    public static let listenHotkeyKey = "ListenHotkey"
    public static let dictationModeKey = "DictationMode"
    public static let microphoneUIDKey = "MicrophoneUID"
    public static let microphoneNameKey = "MicrophoneName"
    public static let engineKey = "Engine"
    public static let historyEnabledKey = "HistoryEnabled"
    public static let setupCompletedKey = "SetupCompleted"

    /// Stored as `[keyCode, modifiers]`; the label is re-derived on read. A stored
    /// combo that fails the rules (hand-edited defaults, an older rule set) reads as
    /// the default rather than registering something unsafe.
    private func combo(_ key: String, fallback: HotkeyManager.Combo) -> HotkeyManager.Combo {
        guard let arr = defaults.array(forKey: key) as? [Int], arr.count == 2,
              arr[0] >= 0, arr[1] >= 0 else { return fallback }
        let c = HotkeyManager.Combo(keyCode: UInt32(arr[0]), modifiers: UInt32(arr[1]))
        return HotkeyRules.validate(c, otherCombo: nil, otherName: "") == nil ? c : fallback
    }
    private func setCombo(_ c: HotkeyManager.Combo?, _ key: String) {
        if let c { defaults.set([Int(c.keyCode), Int(c.modifiers)], forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    public var dictationCombo: HotkeyManager.Combo {
        get { combo(Self.dictationHotkeyKey, fallback: .defaultCombo) }
        nonmutating set { setCombo(newValue.sameKeys(as: .defaultCombo) ? nil : newValue, Self.dictationHotkeyKey) }
    }
    /// A stored Listen combo that collides with dictation reads as the default:
    /// two ids on one combo would make one of them dead.
    public var listenCombo: HotkeyManager.Combo {
        get {
            let c = combo(Self.listenHotkeyKey, fallback: .listen)
            return c.sameKeys(as: dictationCombo) ? .listen : c
        }
        nonmutating set { setCombo(newValue.sameKeys(as: .listen) ? nil : newValue, Self.listenHotkeyKey) }
    }
    public var dictationMode: DictationMode {
        get { defaults.string(forKey: Self.dictationModeKey).flatMap(DictationMode.init(rawValue:)) ?? .toggle }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.dictationModeKey) }
    }
    public var engine: EngineChoice {
        get { defaults.string(forKey: Self.engineKey).flatMap(EngineChoice.init(rawValue:)) ?? .unified }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.engineKey) }
    }
    /// nil = follow the system default input.
    public var microphone: (uid: String, name: String)? {
        get {
            guard let uid = defaults.string(forKey: Self.microphoneUIDKey), !uid.isEmpty else { return nil }
            return (uid, defaults.string(forKey: Self.microphoneNameKey) ?? uid)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.uid, forKey: Self.microphoneUIDKey)
                defaults.set(newValue.name, forKey: Self.microphoneNameKey)
            } else {
                defaults.removeObject(forKey: Self.microphoneUIDKey)
                defaults.removeObject(forKey: Self.microphoneNameKey)
            }
        }
    }
    /// Default ON: the history is the safety net for a paste that landed in the
    /// wrong window, and a safety net you have to find and switch on first is not one.
    public var historyEnabled: Bool {
        get { (defaults.object(forKey: Self.historyEnabledKey) as? Bool) ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.historyEnabledKey) }
    }
    /// The first-run setup window was finished or dismissed (2.5). Unset on a
    /// fresh install; an upgrade with every permission already granted gets it set
    /// silently at launch (`SetupChecklist.launchDecision`).
    public var setupCompleted: Bool {
        get { defaults.bool(forKey: Self.setupCompletedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.setupCompletedKey) }
    }
}
