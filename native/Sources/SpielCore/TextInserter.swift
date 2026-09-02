import AppKit
import ApplicationServices
import Foundation

/// Puts transcribed text into whatever app the user was in.
///
/// This replaces the Electron path, which was the single biggest source of
/// "doesn't work right in some apps":
///   - it shelled out to `osascript` per insertion (a whole process spawn, and a
///     hard dependency on System Events being responsive),
///   - it re-focused the target by DISPLAY NAME (`tell application "Foo" to activate`),
///     which breaks for apps whose AppleScript name differs from their process name
///     and for anything non-scriptable,
///   - it "restored" the clipboard on a bare 100 ms timer, so a slow paste pasted
///     stale content,
///   - and it only saved `readText()`, so an image or file on the pasteboard was
///     destroyed and replaced with plain text.
///
/// The strategy here is two-tier, which is the standard macOS answer: try the
/// Accessibility API first, fall back to a synthetic Cmd+V posted with CGEvent.
/// Neither alone is sufficient -- AX `kAXSelectedTextAttribute` silently no-ops in a
/// large number of apps (it reports success and inserts nothing), and synthetic paste
/// is blocked under Secure Input. So we try AX, VERIFY it, and fall back.
public final class TextInserter: @unchecked Sendable {

    public enum Method: String, Sendable {
        case accessibility
        case paste
        case failed
    }

    public struct Outcome: Sendable {
        public let method: Method
        public let detail: String?
        public var success: Bool { method != .failed }
    }

    /// The app that was frontmost when dictation began. Captured by PID, not name.
    private var previousApp: NSRunningApplication?

    public init() {}

    public func captureFrontmostApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    public var capturedAppName: String? { previousApp?.localizedName }

    /// True if the process has been granted Accessibility. Does NOT prompt.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility if not granted. Shows the system dialog.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// macOS Secure Input blocks synthetic keystrokes. It is also well known for
    /// getting stuck on after you leave a password field. If it is enabled we cannot
    /// paste, and the honest thing is to say so rather than fail silently.
    public static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    @discardableResult
    public func insert(_ text: String) -> Outcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(method: .failed, detail: "nothing to insert")
        }

        refocusPreviousApp()

        if let outcome = tryAccessibilityInsert(text) {
            return outcome
        }

        if Self.isSecureInputEnabled() {
            // Leave the text on the pasteboard so the work is not lost, and say why.
            setPasteboard(text)
            return Outcome(
                method: .failed,
                detail: "macOS Secure Input is active, so synthetic paste is blocked. "
                      + "Your text is on the clipboard -- press Cmd+V."
            )
        }

        return pasteInsert(text)
    }

    // MARK: - Focus

    private func refocusPreviousApp() {
        guard let app = previousApp, !app.isTerminated else { return }
        app.activate()
        // Focus switches are asynchronous. Poll rather than sleeping a fixed guess.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                break
            }
            usleep(15_000)
        }
    }

    // MARK: - Tier 1: Accessibility API

    /// Returns nil if AX is not usable here, so the caller falls through to paste.
    private func tryAccessibilityInsert(_ text: String) -> Outcome? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = previousApp, !app.isTerminated else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard err == .success, let focusedRef = focused else { return nil }
        // swiftlint:disable:next force_cast
        let element = focusedRef as! AXUIElement

        // Only attempt this on an element that actually declares the attribute as
        // settable. Setting it blind is how AX insertion "succeeds" while doing
        // nothing.
        var settable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        guard settableErr == .success, settable.boolValue else { return nil }

        let setErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard setErr == .success else { return nil }

        // VERIFY. A .success return from AX is not proof the text landed -- several
        // apps accept the set and ignore it. Read the value back; if the element
        // won't tell us, treat that as unverified and fall back to paste rather than
        // reporting a success we cannot demonstrate.
        var readback: CFTypeRef?
        let readErr = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &readback
        )
        if readErr == .success, let value = readback as? String {
            if value.contains(text) {
                return Outcome(method: .accessibility, detail: nil)
            }
            return nil  // it lied; fall through to paste
        }
        return nil
    }

    // MARK: - Tier 2: synthetic paste via CGEvent

    private func pasteInsert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        setPasteboard(text)

        guard postCommandV() else {
            restorePasteboard(saved, to: pasteboard)
            return Outcome(method: .failed, detail: "could not post Cmd+V (CGEvent creation failed)")
        }

        // Restore only once the paste has plausibly been consumed. The old code used
        // a flat 100 ms and could clobber a slow app mid-paste. Wait for the target
        // to have had a real turn, then restore all flavors -- not just text.
        let savedSnapshot = saved
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.45) {
            self.restorePasteboard(savedSnapshot, to: NSPasteboard.general)
        }

        return Outcome(method: .paste, detail: nil)
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Suppress local keyboard state so a physically-held modifier doesn't turn
        // this into Cmd+Shift+V or similar.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey: CGKeyCode = 0x09  // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        usleep(12_000)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    // MARK: - Pasteboard, all flavors

    private struct PasteboardSnapshot {
        let items: [[String: Data]]
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var flavors: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    flavors[type.rawValue] = data
                }
            }
            if !flavors.isEmpty { items.append(flavors) }
        }
        return PasteboardSnapshot(items: items)
    }

    private func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pb: NSPasteboard) {
        guard !snapshot.items.isEmpty else { return }
        pb.clearContents()
        var restored: [NSPasteboardItem] = []
        for flavors in snapshot.items {
            let item = NSPasteboardItem()
            for (raw, data) in flavors {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            restored.append(item)
        }
        pb.writeObjects(restored)
    }
}
