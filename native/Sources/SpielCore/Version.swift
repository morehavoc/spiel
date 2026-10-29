import Foundation

/// The one place the version lives. `scripts/bundle.sh` reads both values from this
/// file into Info.plist, and `spiel --version` prints them, so the app and the
/// command-line tool can never disagree about which build they are.
public enum SpielLinks {
    /// The help site (GitHub Pages from docs/ in this repo).
    public static let help = URL(string: "https://morehavoc.com/spiel/")!
    public static let supportEmail = "spiel@christophermoravec.com"
    /// mailto: with the version in the subject, so a reply can say which build.
    public static func supportMail(version: String) -> URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "Spiel \(version)")]
        return c.url!
    }
}

public enum SpielVersion {
    public static let short = "2.8.3"
    public static let build = "17"
}
