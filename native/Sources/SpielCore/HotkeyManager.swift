import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon `RegisterEventHotKey`.
///
/// The important change over the Electron version is not the mechanism -- its
/// `globalShortcut` used the same Carbon call underneath. It is that **failure is
/// surfaced**: registration is system-exclusive, so if another app owns the combo it
/// just fails, and v1 went on sitting in the menu bar looking alive with a dead
/// hotkey. Every registration here ends in a `Status` the app shows in its menu.
///
/// Two hotkeys now (dictation ⌘⇧D, Listen ⌘⇧L), each with its own id, status and
/// handler. The Carbon callback reads the event's `EventHotKeyID` and routes on it.
/// A failed registration of one never touches the other.
///
/// The Carbon calls sit behind `Backend` so `spiel-cli selftest` can drive the
/// routing and failure paths with a stub — registering REAL global hotkeys from a
/// test would steal ⌘⇧D from the running app.
public final class HotkeyManager {

    public enum Status: Equatable, Sendable {
        case unregistered
        case registered(description: String)
        case failed(description: String, reason: String)

        public var isHealthy: Bool { if case .registered = self { return true }; return false }
    }

    public struct Combo: Equatable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public var description: String

        public init(keyCode: UInt32, modifiers: UInt32, description: String) {
            self.keyCode = keyCode; self.modifiers = modifiers; self.description = description
        }

        /// Cmd+Shift+D. Deliberately NOT the old default of Cmd+\ — a backslash
        /// chord collides in terminals and several editors, which is one of the
        /// concrete ways registration used to fail.
        public static let defaultCombo = Combo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey | shiftKey),
            description: "⌘⇧D"
        )
        /// Cmd+Shift+L for Listen.
        public static let listen = Combo(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | shiftKey),
            description: "⌘⇧L"
        )
        public static let f5 = Combo(keyCode: UInt32(kVK_F5), modifiers: 0, description: "F5")
    }

    /// Hotkey identities. Raw values are the `EventHotKeyID.id` sent to Carbon.
    public enum Id: UInt32, CaseIterable, Sendable {
        case dictation = 1
        case listen = 2
    }

    public enum RegisterError: Error, Equatable {
        case handlerInstall(OSStatus)
        case taken
        case failed(OSStatus)
    }

    /// The system calls, abstracted. `register` returns an opaque token that
    /// `unregister` takes back.
    public protocol Backend {
        func installHandler(_ route: @escaping (UInt32) -> Void) -> Result<Void, RegisterError>
        func register(_ combo: Combo, id: UInt32) -> Result<AnyObject, RegisterError>
        func unregister(_ token: AnyObject)
        func removeHandler()
    }

    private var entries: [Id: (combo: Combo, token: AnyObject?, onTrigger: () -> Void)] = [:]
    private var statuses: [Id: Status] = [:]
    private var onStatusChange: ((Id, Status) -> Void)?
    private let backend: Backend
    private var handlerInstalled = false

    public init(backend: Backend = CarbonBackend()) {
        self.backend = backend
    }

    public func status(_ id: Id) -> Status { statuses[id] ?? .unregistered }

    /// Called for every status change, and once per id on install with the
    /// current state. Runs on whatever thread called `register`.
    public func setStatusHandler(_ handler: @escaping (Id, Status) -> Void) {
        onStatusChange = handler
        for id in Id.allCases { handler(id, status(id)) }
    }

    /// Register (or re-register) one hotkey. Only THIS id is unregistered first;
    /// the other keeps working whatever happens here.
    @discardableResult
    public func register(_ id: Id, _ combo: Combo, onTrigger: @escaping () -> Void) -> Status {
        unregister(id)
        if !handlerInstalled {
            switch backend.installHandler({ [weak self] raw in self?.dispatch(raw: raw) }) {
            case .success:
                handlerInstalled = true
            case .failure(let e):
                return finish(id, .failed(description: combo.description,
                                          reason: "could not install the Carbon event handler (\(Self.describe(e)))"))
            }
        }
        switch backend.register(combo, id: id.rawValue) {
        case .success(let token):
            entries[id] = (combo, token, onTrigger)
            return finish(id, .registered(description: combo.description))
        case .failure(let e):
            return finish(id, .failed(description: combo.description, reason: Self.describe(e, combo: combo)))
        }
    }

    private static func describe(_ e: RegisterError, combo: Combo? = nil) -> String {
        switch e {
        case .handlerInstall(let s): return "OSStatus \(s)"
        case .taken: return "another app already owns \(combo?.description ?? "that shortcut")"
        case .failed(let s): return "RegisterEventHotKey failed (OSStatus \(s))"
        }
    }

    /// The route from the Carbon callback: an event whose id matches a registered
    /// entry fires that entry's handler and nothing else. Unknown ids are dropped.
    public func dispatch(raw: UInt32) {
        guard let id = Id(rawValue: raw), let entry = entries[id] else { return }
        entry.onTrigger()
    }

    private func finish(_ id: Id, _ newStatus: Status) -> Status {
        statuses[id] = newStatus
        if case .failed(let desc, let reason) = newStatus {
            NSLog("Spiel: hotkey %@ NOT registered — %@", desc, reason)
        }
        onStatusChange?(id, newStatus)
        return newStatus
    }

    public func unregister(_ id: Id) {
        if let token = entries[id]?.token { backend.unregister(token) }
        entries[id] = nil
        statuses[id] = .unregistered
    }

    public func unregisterAll() {
        for id in Id.allCases { unregister(id) }
        if handlerInstalled { backend.removeHandler(); handlerInstalled = false }
    }

    deinit { unregisterAll() }

    // MARK: - Carbon

    /// The real thing. One `HotkeyManager` per process is the assumption (the
    /// Carbon callback is a C function pointer and needs a static route back).
    public final class CarbonBackend: Backend {
        private var handlerRef: EventHandlerRef?
        nonisolated(unsafe) private static var route: ((UInt32) -> Void)?

        public init() {}

        public func installHandler(_ route: @escaping (UInt32) -> Void) -> Result<Void, RegisterError> {
            Self.route = route
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let err = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ -> OSStatus in
                    var hotKeyID = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                    )
                    guard status == noErr else { return status }
                    let id = hotKeyID.id
                    DispatchQueue.main.async { CarbonBackend.route?(id) }
                    return noErr
                },
                1, &eventType, nil, &handlerRef
            )
            return err == noErr ? .success(()) : .failure(.handlerInstall(err))
        }

        private final class Token { let ref: EventHotKeyRef; init(_ r: EventHotKeyRef) { ref = r } }

        public func register(_ combo: Combo, id: UInt32) -> Result<AnyObject, RegisterError> {
            let hotKeyID = EventHotKeyID(signature: OSType(0x53504C21), id: id)  // 'SPL!'
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            guard err == noErr, let ref else {
                return .failure(err == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(err))
            }
            return .success(Token(ref))
        }

        public func unregister(_ token: AnyObject) {
            if let t = token as? Token { UnregisterEventHotKey(t.ref) }
        }

        public func removeHandler() {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            Self.route = nil
        }
    }
}
