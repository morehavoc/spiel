import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon `RegisterEventHotKey`.
///
/// The important change is not the mechanism -- Electron's `globalShortcut` used the
/// same Carbon call underneath. It is that **failure is surfaced**.
///
/// In the Electron app, `globalShortcut.register()` returning false was handled with a
/// `console.error` and a literal `// Could show an alert about the hotkey conflict`
/// TODO. Registration is system-exclusive, so if any other app already owns the combo
/// it just fails, and Spiel went on sitting in the menu bar looking perfectly alive
/// with a dead hotkey. That is the "it doesn't always turn on" complaint, and it was
/// never a bug in the key handling -- it was a missing error path.
final class HotkeyManager {

    enum Status: Equatable {
        case unregistered
        case registered(description: String)
        case failed(description: String, reason: String)

        var isHealthy: Bool { if case .registered = self { return true }; return false }
    }

    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var description: String

        /// Cmd+Shift+D. Deliberately NOT the old default of Cmd+\ — a backslash
        /// chord collides in terminals and several editors, which is one of the
        /// concrete ways registration used to fail.
        static let defaultCombo = Combo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey | shiftKey),
            description: "⌘⇧D"
        )
        static let f5 = Combo(keyCode: UInt32(kVK_F5), modifiers: 0, description: "F5")
    }

    private(set) var status: Status = .unregistered
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var onStatusChange: ((Status) -> Void)?

    /// The Carbon event callback is a C function pointer and cannot capture context,
    /// so it needs a static route back to the instance. Every read and write happens
    /// on the main thread (the callback immediately hops to `DispatchQueue.main`), so
    /// `nonisolated(unsafe)` states that invariant rather than hiding it.
    nonisolated(unsafe) private static var shared: HotkeyManager?

    init() { HotkeyManager.shared = self }

    func setStatusHandler(_ handler: @escaping (Status) -> Void) {
        onStatusChange = handler
        handler(status)
    }

    @discardableResult
    func register(_ combo: Combo = .defaultCombo, onTrigger: @escaping () -> Void) -> Status {
        unregister()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installErr = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                // Only one hotkey is ever registered, so the event's EventHotKeyID
                // carries no information worth reading back.
                DispatchQueue.main.async { HotkeyManager.shared?.onTrigger?() }
                return noErr
            },
            1, &eventType, nil, &handlerRef
        )
        guard installErr == noErr else {
            return finish(.failed(
                description: combo.description,
                reason: "could not install the Carbon event handler (OSStatus \(installErr))"
            ))
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53504C21), id: 1)  // 'SPL!'
        var ref: EventHotKeyRef?
        let regErr = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard regErr == noErr, let ref else {
            return finish(.failed(
                description: combo.description,
                reason: regErr == OSStatus(eventHotKeyExistsErr)
                    ? "another app already owns \(combo.description)"
                    : "RegisterEventHotKey failed (OSStatus \(regErr))"
            ))
        }
        hotKeyRef = ref
        return finish(.registered(description: combo.description))
    }

    private func finish(_ newStatus: Status) -> Status {
        status = newStatus
        onStatusChange?(newStatus)
        if case .failed(let desc, let reason) = newStatus {
            // Not a console log. This is the whole point of the class.
            NSLog("Spiel: hotkey %@ NOT registered — %@", desc, reason)
            Notifier.post(
                title: "Spiel hotkey is not active",
                body: "\(desc) could not be registered: \(reason). Pick a different shortcut from the Spiel menu."
            )
        }
        return newStatus
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        status = .unregistered
    }

    deinit { unregister() }
}
