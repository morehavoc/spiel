import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Listen screenshots (2.7): the display under the mouse pointer, full screen,
/// as PNG, with Spiel's own windows (the Listen panel) left out by the content
/// filter rather than hidden and re-shown — no flicker.
enum ScreenCapture {

    enum Failure: Error, CustomStringConvertible {
        case noPermission
        case noDisplay
        case capture(String)
        case encode
        var description: String {
            switch self {
            case .noPermission: return "Screen Recording is off for Spiel."
            case .noDisplay: return "No display found under the pointer."
            case .capture(let why): return "Capture failed: \(why)"
            case .encode: return "Could not encode the image."
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lists Spiel
    /// in Privacy & Security → Screen Recording. Returns the current state.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// The display the pointer is on, read on the main thread.
    @MainActor
    static func displayUnderPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func capturePNG(display id: CGDirectDisplayID) async throws -> Data {
        guard hasPermission else { throw Failure.noPermission }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.capture(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == me },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Failure.capture(error.localizedDescription)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encode
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return data as Data
    }
}
