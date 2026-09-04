import Foundation
import ServiceManagement

/// Optional "Open at Login", via `SMAppService.mainApp` (macOS 13+).
///
/// The whole point of this file is that the checkmark tells the TRUTH. The naive
/// version stores a Bool in defaults and ticks the menu from it — and then the
/// menu says "on" while the app does not launch, because the user switched it off
/// in System Settings, or because the bundle it registered no longer exists at
/// that path. macOS already knows the answer, so we ask macOS on every read and
/// never cache a wish.
///
/// Two failure modes are real for Spiel specifically, because it arrives as a
/// downloaded zip:
///
///   * **Translocation.** Launching an unnotarized app straight out of the
///     download makes macOS run it from a read-only, throwaway mount under
///     `/private/var/folders/.../AppTranslocation/`. A login item registered from
///     there points at a path that is gone on the next boot: it would report
///     success and simply never launch. We refuse to register instead.
///   * **Living in ~/Downloads.** Registration works, but replacing the app with
///     the next build breaks it silently. We register and say so.
public enum LaunchAtLogin {

    /// What macOS says right now.
    public enum State: Equatable {
        /// Registered and allowed to launch.
        case on
        /// Not registered.
        case off
        /// Registered, but the user switched it off in System Settings → Login Items.
        /// Only the user can undo that; `register()` cannot.
        case requiresApproval
        /// Cannot be used from this process/bundle at all. The string is the reason,
        /// shown verbatim in the menu — an unexplained disabled item is a bug report.
        case unavailable(String)

        /// Should the menu draw a checkmark? Only `on` earns one.
        public var isChecked: Bool { self == .on }
    }

    // MARK: - Location checks (pure — selftest drives these)

    /// True when the bundle is running from a Gatekeeper app-translocation mount.
    /// A login item registered from one of these points at a path that will not
    /// exist at the next login.
    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// A note about where the app lives, or nil when the location is fine.
    /// Non-fatal — registration still happens; the note is shown so a login item
    /// that later stops working is not a mystery.
    public static func locationNote(bundlePath: String) -> String? {
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix("/System/Applications/") {
            return nil
        }
        if bundlePath.contains("/Downloads/") {
            return "Spiel is in Downloads — replacing it with a new build breaks the login item. Move it to /Applications."
        }
        return "Spiel is not in /Applications — the login item points at its current location and breaks if it moves."
    }

    /// Why registration is impossible here, or nil when it is possible.
    /// Split out from `state()` so selftest can prove the refusals without touching
    /// the user's real login items.
    public static func blocker(bundleIdentifier: String?, bundlePath: String) -> String? {
        guard bundleIdentifier != nil else {
            return "not running as an app bundle (this is the command-line build)"
        }
        if isTranslocated(bundlePath: bundlePath) {
            return "macOS is running Spiel from a temporary read-only copy. Move Spiel.app to /Applications, then reopen it."
        }
        return nil
    }

    // MARK: - Live state

    /// The current state, read from macOS every time. Never cached.
    public static func state() -> State {
        if let why = blocker(bundleIdentifier: Bundle.main.bundleIdentifier,
                             bundlePath: Bundle.main.bundleURL.path) {
            return .unavailable(why)
        }
        return describe(SMAppService.mainApp.status)
    }

    /// Map an `SMAppService.Status` onto our state. Anything unrecognised reads as
    /// `unavailable` and says the raw value — never as `on`, and never as a plain
    /// `off` that invites a click that cannot work.
    public static func describe(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .on
        case .notRegistered: return .off
        case .requiresApproval: return .requiresApproval
        case .notFound:
            return .unavailable("macOS has no record of this copy of Spiel — reopen it from /Applications")
        @unknown default:
            return .unavailable("macOS returned an unrecognised login-item status (\(status.rawValue))")
        }
    }

    /// Turn it on or off. Returns the state read back from macOS AFTERWARDS, so the
    /// caller reports what actually happened rather than what it asked for.
    /// The `error` is non-nil when the call threw.
    @discardableResult
    public static func setEnabled(_ on: Bool) -> (state: State, error: String?) {
        if let why = blocker(bundleIdentifier: Bundle.main.bundleIdentifier,
                             bundlePath: Bundle.main.bundleURL.path) {
            DiagnosticLog.write("launch-at-login: refused to \(on ? "register" : "unregister") — \(why)")
            return (.unavailable(why), why)
        }
        var failure: String?
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        let after = state()
        DiagnosticLog.write("launch-at-login: requested \(on ? "ON" : "off") from \(Bundle.main.bundleURL.path) — "
            + "now \(label(after))\(failure.map { "; error: \($0)" } ?? "")")
        return (after, failure)
    }

    /// Short human label used in the menu, `doctor`, and the log.
    public static func label(_ state: State) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .requiresApproval: return "blocked in System Settings → Login Items"
        case .unavailable(let why): return "unavailable — \(why)"
        }
    }

    /// Deep link to System Settings → General → Login Items. The only way out of
    /// `requiresApproval`: the API cannot re-enable what the user switched off.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
