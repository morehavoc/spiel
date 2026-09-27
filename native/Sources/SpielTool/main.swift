import Foundation
import SpielCore

// `spiel` — the user-facing command line. Scripts and AI agents transcribe files,
// read Listen transcripts and dictation history with it. `spiel-cli` stays the
// developer harness (selftest, replay, boost-eval…).
//
// Contract, also in README § For AI agents: the RESULT goes to stdout and nothing
// else does; progress and diagnostics go to stderr (`--quiet` silences Spiel's
// own); exit 0 ok, 1 usage, 2 file unreadable, 3 engine/model failure, 4 no speech.

typealias Exit = ToolArguments.Exit

// This process must never write into the app's Spiel.log, and DiagnosticLog
// mirrors to NSLog (stderr) — both wrong for a scripting tool.
DiagnosticLog.setEnabled(false, persist: false)

let stderrIsTTY = isatty(STDERR_FILENO) != 0
nonisolated(unsafe) var quiet = false

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func note(_ s: String) { if !quiet { err(s) } }
/// A progress line that rewrites itself on a terminal and is skipped otherwise
/// (a log file full of carriage returns helps nobody).
func live(_ s: String) {
    guard !quiet, stderrIsTTY else { return }
    FileHandle.standardError.write(Data(("\r\u{1B}[K" + s).utf8))
}
func endLive() { if !quiet && stderrIsTTY { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) } }

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

func finish(_ code: Exit) -> Never { exit(code.rawValue) }

func usageError(_ message: String, help: String) -> Never {
    err("spiel: \(message)")
    err(help)
    finish(.usage)
}

let version = "spiel \(SpielVersion.short) (build \(SpielVersion.build))"

let mainHelp = """
spiel \(SpielVersion.short) — on-device transcription from the command line

usage:
  spiel transcribe <file|-> [...] [options]   audio/video file(s) → text
  spiel transcripts [list|show <n|name>|path [<n|name>]] [--json]
                                              Listen transcripts in ~/Documents/Spiel/Transcripts
  spiel history [--json] [-n N]               recent dictations (read-only)
  spiel doctor                                models, versions, permissions
  spiel <command> --help                      options for one command
  spiel --version

Results go to stdout, progress to stderr. Exit: 0 ok, 1 usage, 2 file unreadable,
3 engine/model failure, 4 no speech found.
"""

let transcribeHelp = """
usage: spiel transcribe <file|-> [...] [options]

  <file>              anything AVFoundation reads: wav aiff caf m4a mp3 aac mp4 mov
  -                   read the audio from stdin
  -f, --format FMT    text (default) | md | srt | vtt | json
  -e, --engine E      unified | v3 | apple (default: the engine chosen in Spiel's
                      Settings, falling back like the app; an explicit engine does
                      not fall back)
  --vocab V           builtin | none | <file> (default: your vocabulary.txt merged
                      over the built-in terms, as the app uses)
  -o, --output PATH   write there instead of stdout; with several files, a folder
                      (created) receiving <name>.<ext> per file
  -q, --quiet         no progress or diagnostics on stderr
  -h, --help

Several files: json prints an array; text/md print each under "==> name <=="; srt/vtt
need -o <folder>. Exit: 0 ok, 1 usage, 2 unreadable file, 3 engine/model failure
(or some segments failed — the output holds what did transcribe), 4 no speech found.
With several files every file is attempted and the exit is the most severe of 3, 2, 4.
"""

let transcriptsHelp = """
usage: spiel transcripts [list] [--json] [-n N]
       spiel transcripts show <n|name>      print one (1 = newest; or a unique part of the name)
       spiel transcripts path [<n|name>]    the folder, or one file's full path
"""

let historyHelp = """
usage: spiel history [--json] [-n N]
  The last dictations Spiel kept (Settings → History), newest first. Read-only.
"""

// MARK: - transcribe

func makeTranscriber(_ e: EngineChoice, progress: ModelProgressHandler?) -> Transcriber {
    switch e {
    case .unified: return ParakeetUnifiedTranscriber(progress: progress)
    case .v3: return ParakeetTranscriber(progress: progress)
    case .apple: return AppleSpeechTranscriber()
    }
}

/// Download progress on stderr: a rewriting line on a terminal, a line per 10 %
/// otherwise, and one line when compiling starts.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDecile = -1
    private var saidCompiling = false
    private var sawDownload = false
    let name: String
    /// FluidAudio walks the file list and reports it even when every file is
    /// already cached, so "downloading 100 %" on every run would be a lie; only a
    /// model that was missing at the start gets download lines.
    let downloading: Bool
    init(name: String, downloading: Bool) { self.name = name; self.downloading = downloading }

    func handle(_ p: ModelLoadProgress) {
        lock.lock(); defer { lock.unlock() }
        guard downloading else { return }
        switch p.phase {
        case .listing:
            break
        case .downloading(let done, let total):
            sawDownload = true
            let pct = Int(((p.downloadFraction ?? 0) * 100).rounded(.down))
            let files = total > 0 ? " (\(done) of \(total) files)" : ""
            if stderrIsTTY {
                live("downloading \(name): \(pct)%\(files)")
            } else if pct / 10 > lastDecile {
                lastDecile = pct / 10
                note("spiel: downloading \(name): \(pct)%\(files)")
            }
        case .compiling:
            guard sawDownload, !saidCompiling else { return }
            saidCompiling = true
            endLive()
            note("spiel: preparing \(name) for the Neural Engine (first run only)…")
        }
    }
}

func loadGlossary(_ v: ToolArguments.Vocab) -> Glossary {
    switch v {
    case .user: return Glossary.load()
    case .builtin: return Glossary()
    case .none: return Glossary(entries: [:])
    case .file(let path):
        // Glossary.load falls back to the built-ins on an unreadable file — right for
        // the app, wrong for a script that named a file.
        guard FileManager.default.isReadableFile(atPath: path) else {
            err("spiel: cannot read vocabulary file \(path)")
            finish(.unreadable)
        }
        return Glossary.load(userFile: URL(fileURLWithPath: path))
    }
}

/// Engine + Silero VAD, loaded once for every file. Tries the explicit engine only,
/// or the Settings engine and then the others in the app's order.
func prepareSession(_ o: ToolArguments.Transcribe, glossary: Glossary) async -> (DictationSession, EngineChoice) {
    let chosen = o.engine ?? SpielSettings().engine
    let order = o.engine == nil ? EngineChoice.fallbackOrder(chosen) : [chosen]
    var failures: [String] = []
    for choice in order {
        let missing = choice != .apple && !SpeechModels.isDownloaded(choice)
        let printer = ProgressPrinter(name: SpeechModels.displayName(choice), downloading: missing)
        if missing {
            note("spiel: \(SpeechModels.displayName(choice)) is not on this Mac yet — downloading it once (about \(SpeechModels.approximateMB(choice) ?? 0) MB) to \(DiagnosticsBundle.modelsFolder.path)")
        }
        let transcriber = makeTranscriber(choice, progress: { printer.handle($0) })
        let session = DictationSession(transcriber: transcriber, glossary: glossary)
        let t0 = Date()
        do {
            try await session.prepare()
            endLive()
            if choice == .unified, !glossary.entries.isEmpty {
                let ctc = DiagnosticsBundle.modelsFolder.appendingPathComponent("parakeet-ctc-110m-coreml")
                if !FileManager.default.fileExists(atPath: ctc.path) {
                    note("spiel: downloading the vocabulary-boost model once (about 100 MB)…")
                }
                // Awaited here, unlike the app, so the first file is boosted too.
                await transcriber.setVocabulary(glossary.entries)
                if let u = transcriber as? ParakeetUnifiedTranscriber, let e = await u.boostError {
                    note("spiel: vocabulary boost unavailable, plain transcription continues: \(e)")
                }
            }
            if choice != chosen {
                note("spiel: \(chosen.engineName) unavailable, using \(choice.engineName)")
            }
            note("spiel: engine \(choice.engineName) ready (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
            return (session, choice)
        } catch {
            endLive()
            failures.append("\(choice.engineName): \(error)")
            if order.count > 1 { note("spiel: \(choice.engineName) failed to load: \(error)") }
        }
    }
    err("spiel: no speech engine could load — \(failures.joined(separator: "; "))")
    err("spiel: a first run downloads the model; check the internet connection and try again")
    finish(.engine)
}

/// Stdin → a temp file named with the extension its first bytes imply.
func spoolStdin() -> URL {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
        err("spiel: stdin was empty")
        finish(.unreadable)
    }
    let ext = AudioFileReader.sniffExtension(data) ?? "wav"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-stdin-\(UUID().uuidString).\(ext)")
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        err("spiel: could not spool stdin to \(url.path)")
        finish(.unreadable)
    }
    return url
}

func clock(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

func runTranscribe(_ args: [String]) async -> Never {
    let o: ToolArguments.Transcribe
    switch ToolArguments.parseTranscribe(args) {
    case .failure(let e): usageError(e.message, help: transcribeHelp)
    case .success(let v): o = v
    }
    if o.help { out(transcribeHelp + "\n"); finish(.ok) }
    quiet = o.quiet

    // Where results go, decided before any model loads so a bad -o fails fast.
    var outputFolder: URL?
    if let path = o.output, o.inputs.count > 1 {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            usageError("-o \(path) is a file; with several inputs it must be a folder", help: transcribeHelp)
        }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            err("spiel: cannot create \(path): \(error.localizedDescription)")
            finish(.unreadable)
        }
        outputFolder = url
    }

    // Fail on a missing file before paying for a model load.
    var inputs: [(name: String, url: URL, temp: Bool)] = []
    var worst: Exit = .ok
    func escalate(_ e: Exit) {
        let rank: [Exit: Int] = [.ok: 0, .noSpeech: 1, .unreadable: 2, .engine: 3]
        if rank[e, default: 0] > rank[worst, default: 0] { worst = e }
    }
    for path in o.inputs {
        if path == "-" { inputs.append(("-", spoolStdin(), true)); continue }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || isDir.boolValue {
            err("spiel: \(path): \(isDir.boolValue ? "is a folder" : "no such file")")
            escalate(.unreadable)
            continue
        }
        inputs.append((path, URL(fileURLWithPath: path), false))
    }
    defer { for i in inputs where i.temp { try? FileManager.default.removeItem(at: i.url) } }
    guard !inputs.isEmpty else { finish(worst) }

    let glossary = loadGlossary(o.vocab)
    let (session, engine) = await prepareSession(o, glossary: glossary)

    var results: [(input: String, transcript: FileTranscript)] = []
    for (n, input) in inputs.enumerated() {
        let label = inputs.count > 1 ? "[\(n + 1)/\(inputs.count)] \(input.name)" : input.name
        let t0 = Date()
        let outcome: FileTranscriber.Outcome
        do {
            outcome = try await FileTranscriber.run(input.url, displayName: input.name == "-" ? "-" : input.url.lastPathComponent,
                                                    engine: engine.engineName, session: session) { done, total in
                live(total > 0 ? "transcribing \(label): \(clock(done)) / \(clock(total))" : "transcribing \(label): \(clock(done))")
            }
        } catch {
            endLive()
            err("spiel: \(input.name): \(error)")
            escalate(.unreadable)
            continue
        }
        endLive()
        let t = outcome.transcript
        let secs = Date().timeIntervalSince(t0)
        if !t.errors.isEmpty {
            err("spiel: \(input.name): \(t.errors.count) segment(s) failed — \(t.errors.joined(separator: "; "))")
            escalate(.engine)
        }
        if t.text.isEmpty {
            if t.errors.isEmpty {
                err("spiel: \(input.name): no speech found — \(outcome.diagnosis)")
                escalate(.noSpeech)
            }
        } else {
            note("spiel: \(label): \(t.words) words, \(t.segments.count) segment\(t.segments.count == 1 ? "" : "s"), \(clock(t.durationSeconds)) of audio in \(String(format: "%.1f", secs)) s")
        }
        results.append((input.name, t))
    }

    // Output. A no-speech file still yields its JSON object (empty text) — a
    // script that asked for json gets json — but no text/md/subtitle body.
    if let folder = outputFolder {
        for r in results where o.format == .json || !r.transcript.text.isEmpty {
            let url = folder.appendingPathComponent(ToolArguments.outputName(for: r.input, format: o.format))
            do { try r.transcript.render(o.format).write(to: url, atomically: true, encoding: .utf8) } catch {
                err("spiel: cannot write \(url.path): \(error.localizedDescription)")
                escalate(.unreadable)
                continue
            }
            note("spiel: wrote \(url.path)")
        }
    } else {
        var body = ""
        if o.format == .json {
            if !results.isEmpty {
                body = FileTranscript.json(results.map(\.transcript), asArray: o.inputs.count > 1)
            }
        } else if o.inputs.count > 1 {
            for r in results where !r.transcript.text.isEmpty {
                body += "==> \(r.input) <==\n" + r.transcript.render(o.format) + "\n"
            }
        } else if let r = results.first, !r.transcript.text.isEmpty {
            body = r.transcript.render(o.format)
        }
        if let path = o.output {
            do {
                try body.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                if !body.isEmpty { note("spiel: wrote \(path)") }
            } catch {
                err("spiel: cannot write \(path): \(error.localizedDescription)")
                escalate(.unreadable)
            }
        } else {
            out(body)
        }
    }
    for i in inputs where i.temp { try? FileManager.default.removeItem(at: i.url) }
    finish(worst)
}

// MARK: - transcripts

func runTranscripts(_ args: [String]) -> Never {
    let o: ToolArguments.Listing
    switch ToolArguments.parseListing(args) {
    case .failure(let e): usageError(e.message, help: transcriptsHelp)
    case .success(let v): o = v
    }
    if o.help { out(transcriptsHelp + "\n"); finish(.ok) }
    let folder = TranscriptStore.defaultFolder
    let sub = o.rest.first ?? "list"
    let items: [ListenTranscripts.Item]
    if FileManager.default.fileExists(atPath: folder.path) {
        do { items = try ListenTranscripts.list(in: folder) } catch {
            err("spiel: cannot read \(folder.path): \(error.localizedDescription)")
            err("spiel: if your terminal was refused access to Documents, allow it in System Settings → Privacy & Security → Files and Folders")
            finish(.unreadable)
        }
    } else {
        items = []
    }
    func pick(_ ref: String) -> ListenTranscripts.Item {
        let (item, candidates) = ListenTranscripts.resolve(ref, in: items)
        if let item { return item }
        if candidates.isEmpty {
            err("spiel: no transcript matches '\(ref)' (\(items.count) in \(folder.path))")
            finish(.unreadable)
        }
        err("spiel: '\(ref)' matches \(candidates.count) transcripts — be more specific or use the number:")
        for c in candidates { err("  \(c.number)  \(c.name)") }
        finish(.usage)
    }
    switch sub {
    case "list":
        let shown = o.limit.map { Array(items.prefix($0)) } ?? items
        if o.json {
            let arr: [[String: Any]] = shown.map { i in
                var d: [String: Any] = ["number": i.number, "name": i.name, "path": i.path, "title": i.title]
                d["started"] = i.started ?? NSNull()
                d["duration_s"] = i.durationSeconds ?? NSNull()
                d["words"] = i.words ?? NSNull()
                return d
            }
            let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
            out(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            if items.isEmpty { note("spiel: no Listen transcripts yet (\(folder.path))") }
            for i in shown {
                var facts: [String] = []
                if let d = i.durationSeconds { facts.append(TranscriptDocument.formatDuration(Double(d))) }
                if let w = i.words { facts.append("\(w) words") }
                out("\(i.number)  \(i.name)\(facts.isEmpty ? "" : " — " + facts.joined(separator: ", "))\n")
            }
        }
    case "show":
        guard o.rest.count >= 2 else { usageError("show needs a transcript number or name", help: transcriptsHelp) }
        let item = pick(o.rest[1])
        guard let data = FileManager.default.contents(atPath: item.path) else {
            err("spiel: cannot read \(item.path)")
            finish(.unreadable)
        }
        out(String(decoding: data, as: UTF8.self))
    case "path":
        out((o.rest.count >= 2 ? pick(o.rest[1]).path : folder.path) + "\n")
    default:
        usageError("unknown transcripts command '\(sub)'", help: transcriptsHelp)
    }
    finish(.ok)
}

// MARK: - history

func runHistory(_ args: [String]) -> Never {
    let o: ToolArguments.Listing
    switch ToolArguments.parseListing(args) {
    case .failure(let e): usageError(e.message, help: historyHelp)
    case .success(let v): o = v
    }
    if o.help { out(historyHelp + "\n"); finish(.ok) }
    guard o.rest.isEmpty else { usageError("unexpected '\(o.rest[0])'", help: historyHelp) }
    let loaded = DictationHistory.load()
    if let n = loaded.note {
        err("spiel: \(n) (\(DictationHistory.defaultURL.path))")
        finish(.unreadable)
    }
    var entries = loaded.history.newestFirst
    if let limit = o.limit { entries = Array(entries.prefix(limit)) }
    if !SpielSettings().historyEnabled { note("spiel: history is switched off in Spiel's Settings — showing what was kept before") }
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone.current
    if o.json {
        let arr: [[String: Any]] = entries.map {
            ["date": iso.string(from: $0.date), "app": $0.app ?? NSNull(), "words": $0.words, "text": $0.text]
        }
        let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        out(String(decoding: data, as: UTF8.self) + "\n")
    } else {
        if entries.isEmpty { note("spiel: no dictations in history (\(DictationHistory.defaultURL.path))") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for e in entries {
            let flat = e.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            out("\(f.string(from: e.date)) · \(e.app ?? "unknown app") · \(e.words) words: \(flat)\n")
        }
    }
    finish(.ok)
}

// MARK: - doctor

func runDoctor() -> Never {
    let s = SpielSettings()
    func line(_ k: String, _ v: String) { out(k.padding(toLength: 22, withPad: " ", startingAt: 0) + ": " + v + "\n") }
    out("\(version)\n")
    line("binary", Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0])
    line("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
    line("chip", DiagnosticsBundle.chip())
    line("engine setting", "\(s.engine.rawValue) (\(s.engine.engineName))")
    for e in EngineChoice.allCases {
        if e == .apple {
            line("model apple", AppleSpeechTranscriber.isAvailable ? "SpeechAnalyzer available (the OS downloads its model on first use)" : "not available (needs macOS 26)")
        } else {
            let bytes = SpeechModels.bytesOnDisk(e)
            let state = SpeechModels.isDownloaded(e) ? "present" : bytes > 0 ? "INCOMPLETE" : "not downloaded"
            line("model \(e.rawValue)", "\(state)\(bytes > 0 ? ", " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "") — \(SpeechModels.folder(e)!.path)")
        }
    }
    line("models folder", "\(DiagnosticsBundle.modelsFolder.path) (shared with Spiel.app)")
    let g = Glossary.load()
    line("vocabulary", FileManager.default.fileExists(atPath: Glossary.userFileURL.path)
         ? "\(g.count) aliases (\(Glossary.userFileURL.path) + built-in)" : "built-in only (\(Glossary().count) aliases)")
    let folder = TranscriptStore.defaultFolder
    let tState: String
    if !FileManager.default.fileExists(atPath: folder.path) { tState = "none yet" }
    else if let items = try? ListenTranscripts.list(in: folder) { tState = "\(items.count) readable" }
    else { tState = "NOT readable from this terminal — allow it Documents access in System Settings → Privacy & Security → Files and Folders" }
    line("Listen transcripts", "\(tState) — \(folder.path)")
    let h = DictationHistory.load()
    line("history", "\(h.note ?? "\(h.history.entries.count) entries")\(s.historyEnabled ? "" : " (history is off in Settings)") — \(DictationHistory.defaultURL.path)")
    line("permissions", "none needed to transcribe files (no microphone, no Accessibility); reading Listen transcripts needs this terminal to have Documents access")
    finish(.ok)
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { err(mainHelp); finish(.usage) }
let rest = Array(args.dropFirst())

switch command {
case "--version", "version":
    out(version + "\n")
    finish(.ok)
case "-h", "--help", "help":
    out(mainHelp + "\n")
    finish(.ok)
case "transcribe":
    // Detached (top-level code is @MainActor), and the main thread parks in
    // dispatchMain() rather than a semaphore, so nothing that hops to the main
    // queue can deadlock. runTranscribe always ends the process itself.
    Task.detached { await runTranscribe(rest) }
    dispatchMain()
case "transcripts":
    runTranscripts(rest)
case "history":
    runHistory(rest)
case "doctor":
    if rest.contains("-h") || rest.contains("--help") { out("usage: spiel doctor\n"); finish(.ok) }
    runDoctor()
default:
    usageError("unknown command '\(command)'", help: mainHelp)
}
