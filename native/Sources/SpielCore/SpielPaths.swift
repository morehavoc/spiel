import Foundation

/// The user's home folder on the Mac; the app's container on iOS, where
/// `homeDirectoryForCurrentUser` does not exist. Same layout under both, so
/// `Documents/Spiel/Transcripts` is the Files app's "On My iPhone › Spiel".
enum SpielPaths {
    static var home: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
