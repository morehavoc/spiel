/// The one place the version lives. `scripts/bundle.sh` reads both values from this
/// file into Info.plist, and `spiel --version` prints them, so the app and the
/// command-line tool can never disagree about which build they are.
public enum SpielVersion {
    public static let short = "2.5.2"
    public static let build = "7"
}
