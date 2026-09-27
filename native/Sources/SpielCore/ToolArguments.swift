import Foundation

/// Argument parsing for the user-facing `spiel` command. Pure, so selftest pins the
/// rules an agent scripting against `spiel` depends on.
public enum ToolArguments {

    /// Exit statuses — documented in README § For AI agents. Changing one is a
    /// breaking change for every script that branches on it.
    public enum Exit: Int32, Sendable {
        case ok = 0
        case usage = 1
        case unreadable = 2
        case engine = 3
        case noSpeech = 4
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ m: String) { message = m }
        public var description: String { message }
    }

    public enum Vocab: Equatable, Sendable {
        /// The app's list: `vocabulary.txt` merged over the built-in terms.
        case user
        case builtin
        case none
        case file(String)
    }

    public struct Transcribe: Equatable, Sendable {
        public var inputs: [String] = []
        public var format: FileTranscript.Format = .text
        /// nil = the engine chosen in Spiel's Settings, falling back like the app.
        public var engine: EngineChoice?
        public var vocab: Vocab = .user
        public var output: String?
        public var quiet = false
        public var help = false
        public init() {}
    }

    public static func parseTranscribe(_ args: [String]) -> Result<Transcribe, UsageError> {
        var o = Transcribe()
        var i = 0
        var endOfOptions = false
        func value(_ flag: String) -> Result<String, UsageError> {
            guard i + 1 < args.count else { return .failure(UsageError("\(flag) needs a value")) }
            i += 1
            return .success(args[i])
        }
        while i < args.count {
            let a = args[i]
            if endOfOptions || a == "-" || !a.hasPrefix("-") {
                o.inputs.append(a)
                i += 1
                continue
            }
            switch a {
            case "--":
                endOfOptions = true
            case "-h", "--help":
                o.help = true
            case "-q", "--quiet":
                o.quiet = true
            case "-f", "--format":
                switch value(a) {
                case .failure(let e): return .failure(e)
                case .success(let v):
                    guard let f = FileTranscript.Format(rawValue: v) else {
                        return .failure(UsageError("unknown format '\(v)' — use text, md, srt, vtt or json"))
                    }
                    o.format = f
                }
            case "-e", "--engine":
                switch value(a) {
                case .failure(let e): return .failure(e)
                case .success(let v):
                    guard let e = EngineChoice(rawValue: v) else {
                        return .failure(UsageError("unknown engine '\(v)' — use unified, v3 or apple"))
                    }
                    o.engine = e
                }
            case "--vocab":
                switch value(a) {
                case .failure(let e): return .failure(e)
                case .success(let v):
                    switch v {
                    case "builtin": o.vocab = .builtin
                    case "none": o.vocab = .none
                    case "user", "default": o.vocab = .user
                    default: o.vocab = .file(v)
                    }
                }
            case "-o", "--output":
                switch value(a) {
                case .failure(let e): return .failure(e)
                case .success(let v): o.output = v
                }
            default:
                return .failure(UsageError("unknown option '\(a)'"))
            }
            i += 1
        }
        if o.help { return .success(o) }
        if o.inputs.isEmpty { return .failure(UsageError("no input file (use - to read audio from stdin)")) }
        if o.inputs.filter({ $0 == "-" }).count > 1 { return .failure(UsageError("stdin (-) can be read only once")) }
        if o.inputs.count > 1, o.output == nil, o.format == .srt || o.format == .vtt {
            return .failure(UsageError("\(o.format.rawValue) for several files needs -o <folder> (one subtitle file each)"))
        }
        return .success(o)
    }

    /// `-n N` and `--json`, the options `spiel history` and `spiel transcripts` share.
    public struct Listing: Equatable, Sendable {
        public var json = false
        public var limit: Int?
        public var help = false
        public var rest: [String] = []
        public init() {}
    }

    public static func parseListing(_ args: [String]) -> Result<Listing, UsageError> {
        var o = Listing()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json": o.json = true
            case "-h", "--help": o.help = true
            case "-n":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
                    return .failure(UsageError("-n needs a positive number"))
                }
                o.limit = n
                i += 1
            default:
                if a.hasPrefix("-") && a.count > 1 { return .failure(UsageError("unknown option '\(a)'")) }
                o.rest.append(a)
            }
            i += 1
        }
        return .success(o)
    }

    /// Output file for one input when `-o` names a folder: `talk.m4a` → `talk.srt`.
    public static func outputName(for input: String, format: FileTranscript.Format) -> String {
        let base = input == "-" ? "stdin" : URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
        return base + "." + format.fileExtension
    }
}
