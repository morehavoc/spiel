import AVFoundation
import Foundation
import SpielCore

/// 2.5 — the `spiel` command's contract (arguments, exit codes, output formats),
/// file transcription through the real pipeline, the setup checklist, and the
/// command-line installer. Everything here runs without a model, a mic or TCC.
extension SelfTest {

    static func tests25() async {
        toolArgumentTests()
        exportFormatTests()
        sniffTests()
        setupChecklistTests()
        modelFolderTests()
        installerTests()
        listenListingTests()
        await fileTranscriberTests()
        appSourceRules25()
    }

    // MARK: Arguments + exit codes

    static func toolArgumentTests() {
        print("\n2.5 — spiel arguments and exit codes (the scripting contract)")
        expect(ToolArguments.Exit.allRaw, "0 1 2 3 4", "exit codes: ok 0, usage 1, unreadable 2, engine 3, no speech 4")

        func ok(_ a: [String]) -> ToolArguments.Transcribe? {
            if case .success(let o) = ToolArguments.parseTranscribe(a) { return o }
            return nil
        }
        func fails(_ a: [String]) -> String {
            if case .failure(let e) = ToolArguments.parseTranscribe(a) { return e.message }
            return "(accepted)"
        }
        let d = ok(["a.m4a"])
        expect(d.map { "\($0.inputs) \($0.format.rawValue) \($0.engine?.rawValue ?? "settings") \($0.vocab) q=\($0.quiet)" } ?? "nil",
               "[\"a.m4a\"] text settings user q=false",
               "defaults: text, the Settings engine, the user's vocabulary, not quiet")
        let full = ok(["-f", "json", "--engine", "v3", "--vocab", "none", "-o", "out.json", "-q", "a.wav", "-"])
        expect(full.map { "\($0.inputs) \($0.format.rawValue) \($0.engine!.rawValue) \($0.vocab) \($0.output!) \($0.quiet)" } ?? "nil",
               "[\"a.wav\", \"-\"] json v3 none out.json true", "every option parsed; - is an input (stdin)")
        expect(ok(["--vocab", "builtin", "x"]).map { "\($0.vocab)" } ?? "nil", "builtin", "--vocab builtin")
        expect(ok(["--vocab", "/tmp/v.txt", "x"]).map { "\($0.vocab)" } ?? "nil", "file(\"/tmp/v.txt\")", "--vocab <path>")
        expect(ok(["--", "-odd name.wav"]).map { "\($0.inputs)" } ?? "nil", "[\"-odd name.wav\"]", "-- ends options (a file named with a dash)")
        expect(fails(["--format", "docx", "a"]).contains("unknown format") ? "usage" : "missed", "usage", "an unknown format is a usage error")
        expect(fails(["--engine", "whisper", "a"]).contains("unknown engine") ? "usage" : "missed", "usage", "an unknown engine is a usage error")
        expect(fails(["--bogus", "a"]).contains("unknown option") ? "usage" : "missed", "usage", "an unknown option is a usage error, not a file name")
        expect(fails(["a", "-o"]).contains("needs a value") ? "usage" : "missed", "usage", "-o with nothing after it")
        expect(fails([]).contains("no input") ? "usage" : "missed", "usage", "no input file")
        expect(fails(["-", "-"]).contains("once") ? "usage" : "missed", "usage", "stdin twice is refused")
        expect(fails(["a", "b", "-f", "srt"]).contains("-o") ? "usage" : "missed", "usage",
               "srt for several files to stdout is refused (concatenated SRT is not SRT)")
        expect(ok(["a", "b", "-f", "srt", "-o", "dir"]) != nil ? "ok" : "refused", "ok", "…and allowed with -o <folder>")
        expect(ok(["--help"])?.help == true ? "help" : "no", "help", "--help parses without an input")

        func listing(_ a: [String]) -> String {
            switch ToolArguments.parseListing(a) {
            case .success(let o): return "json=\(o.json) n=\(o.limit.map(String.init) ?? "all") rest=\(o.rest)"
            case .failure(let e): return "error: \(e.message)"
            }
        }
        expect(listing(["show", "3", "--json", "-n", "5"]), "json=true n=5 rest=[\"show\", \"3\"]", "listing options")
        expect(listing(["-n", "0"]).hasPrefix("error") ? "error" : "accepted", "error", "-n 0 is refused")
        expect(listing(["--nope"]).hasPrefix("error") ? "error" : "accepted", "error", "unknown listing option is refused")
        expect(ToolArguments.outputName(for: "/x/talk.final.m4a", format: .srt), "talk.final.srt", "-o folder names: extension swapped")
        expect(ToolArguments.outputName(for: "-", format: .text), "stdin.txt", "…stdin becomes stdin.txt")
    }

    // MARK: Formats

    static func exportFormatTests() {
        print("\n2.5 — transcript formats (text, md, srt, vtt, json)")
        expect(FileTranscript.timestamp(3661.5, vtt: false), "01:01:01,500", "SRT timestamp HH:MM:SS,mmm")
        expect(FileTranscript.timestamp(0.0004, vtt: true), "00:00:00.000", "VTT timestamp HH:MM:SS.mmm, rounded to ms")
        expect(FileTranscript.timestamp(59.9996, vtt: true), "00:01:00.000", "…rounding carries into the minute")

        let t = FileTranscript(file: "talk \"one\".m4a", durationSeconds: 20.25, engine: "parakeet-unified-en-0.6b", segments: [
            TimedSegment(start: 0.5, end: 3.0, text: "Hello there."),
            TimedSegment(start: 4.0, end: 6.0, text: "Second bit."),          // 1.0 s pause → same paragraph
            TimedSegment(start: 8.0, end: 8.0, text: "New paragraph \"quoted\"\nline"),  // 2.0 s → new paragraph
        ])
        expect(t.text, "Hello there. Second bit.\n\nNew paragraph \"quoted\"\nline", "paragraph break at a ≥ 2 s pause, none at 1 s")
        expectInt(t.words, 8, "word count from the text")
        let srt = t.render(.srt)
        expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:03,000\nHello there.\n\n2\n") ? "ok" : srt, "ok", "SRT: numbered cues, comma milliseconds")
        expect(srt.contains("00:00:08,000 --> 00:00:08,500") ? "ok" : "zero-length", "ok", "a zero-length segment gets a 0.5 s cue (players drop empty cues)")
        let vtt = t.render(.vtt)
        expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:03.000\nHello there.\n") ? "ok" : vtt, "ok", "VTT: header, no cue numbers, dot milliseconds")
        let md = t.render(.md)
        expect(md.contains("\n[00:01] Hello there. Second bit.\n\n[00:08] New paragraph") ? "ok" : md, "ok", "md: [MM:SS] paragraphs like a Listen transcript")
        expect(md.contains("source: file\n") && md.contains("kind: transcript\n") ? "ok" : "missing", "ok", "md frontmatter says kind/source")

        let json = t.render(.json)
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        expect(obj == nil ? "invalid" : "valid", "valid", "json parses (quotes and a newline in the text)")
        if let obj {
            expect(obj.keys.sorted().joined(separator: ","), "duration_s,engine,errors,file,segments,text,words", "json has exactly the documented keys")
            expect(obj["text"] as? String ?? "", t.text, "json text == the text format's body")
            expect("\(obj["duration_s"] ?? "")", "20.25", "duration_s printed without float noise")
            let segs = obj["segments"] as? [[String: Any]] ?? []
            expect(segs.map { "\($0["start"]!)-\($0["end"]!)" }.joined(separator: " "), "0.5-3 4-6 8-8", "segments carry start/end seconds")
        }
        expect(json.hasPrefix("{\n  \"file\": ") ? "ok" : String(json.prefix(20)), "ok", "json key order: file first (read by eye too)")
        let arr = (try? JSONSerialization.jsonObject(with: Data(FileTranscript.json([t, t], asArray: true).utf8))) as? [Any]
        expectInt(arr?.count ?? -1, 2, "several files → a JSON array")
        let empty = FileTranscript(file: "s.wav", durationSeconds: 5, engine: "e", segments: [])
        expect(empty.render(.text), "", "no speech → text prints nothing (the exit code says why)")
        let eobj = (try? JSONSerialization.jsonObject(with: Data(empty.render(.json).utf8))) as? [String: Any]
        expect(eobj.map { "\(($0["segments"] as? [Any])?.count ?? -1) \($0["text"] ?? "")|" } ?? "invalid", "0 |", "no speech → json still valid, empty segments and text")
        expect(FileTranscriber.fileDiagnosis(audioSeconds: 5, peak: 0, segments: 0, errors: []).contains("mic") ? "mic advice" : "ok", "ok",
               "a silent FILE is not diagnosed as a muted microphone")
    }

    static func sniffTests() {
        print("\n2.5 — stdin container sniffing")
        func sniff(_ bytes: [UInt8]) -> String { AudioFileReader.sniffExtension(Data(bytes)) ?? "nil" }
        func a(_ s: String) -> [UInt8] { Array(s.utf8) }
        expect(sniff(a("RIFF") + [0, 0, 0, 0] + a("WAVE")), "wav", "RIFF/WAVE → wav")
        expect(sniff(a("FORM") + [0, 0, 0, 0] + a("AIFF")), "aiff", "FORM/AIFF → aiff")
        expect(sniff(a("caff") + [0, 1, 0, 0]), "caf", "caff → caf")
        expect(sniff([0, 0, 0, 0x20] + a("ftypM4A ")), "mp4", "ftyp M4A → mp4 container")
        expect(sniff([0, 0, 0, 0x14] + a("ftypqt  ")), "mov", "ftyp qt → mov")
        expect(sniff(a("ID3") + [4, 0, 0]), "mp3", "ID3 tag → mp3")
        expect(sniff([0xFF, 0xFB, 0x90, 0x00]), "mp3", "MPEG frame sync → mp3")
        expect(sniff([0xFF, 0xF1, 0x50, 0x80]), "aac", "ADTS sync (layer 00) → aac")
        expect(sniff(a("not audio")), "nil", "unknown bytes → nil (read is attempted, then reported)")
    }

    // MARK: Setup

    static func setupChecklistTests() {
        print("\n2.5 — first-run setup: which launches open the window")
        let all = SetupChecklist(microphone: .authorized, accessibility: true, notifications: .allowed, modelOnDisk: true)
        func decide(_ completed: Bool, _ c: SetupChecklist) -> String { "\(SetupChecklist.launchDecision(completed: completed, c))" }
        expect(decide(false, all), "markDone", "upgrade with everything granted: no window, flag set silently")
        expect(decide(true, all), "skip", "setup done before: nothing new")
        var c = all; c.microphone = .notDetermined
        expect(decide(false, c), "show", "fresh install (mic not asked): window")
        expect(decide(true, c), "skip", "…but never re-opens once finished or dismissed (the menu has Setup…)")
        c = all; c.microphone = .denied
        expect(decide(false, c), "show", "mic denied is NOT done — dictation cannot work")
        c = all; c.notifications = .denied
        expect(decide(false, c), "markDone", "notifications denied counts as answered (no nagging over an optional permission)")
        c = all; c.notifications = .notDetermined
        expect(decide(false, c), "show", "notifications never asked: window")
        c = all; c.accessibility = false
        expect(decide(false, c), "show", "accessibility missing: window")
        c = all; c.modelOnDisk = false
        expect(c.remaining.joined(separator: ","), "speech model", "model not downloaded is a remaining step")

        let dl = ModelLoadProgress(phase: .downloading(completedFiles: 1, totalFiles: 4), rawFraction: 0.25)
        expect(dl.downloadFraction.map { String(format: "%.2f", $0) } ?? "nil", "0.50",
               "download bar = FluidAudio fraction ÷ its 0.5 download weight (0.25 overall = half downloaded)")
        expect(ModelLoadProgress(phase: .downloading(completedFiles: 4, totalFiles: 4), rawFraction: 0.5).downloadFraction
               .map { String($0) } ?? "nil", "1.0", "0.5 overall = download complete")
        expect(ModelLoadProgress(phase: .downloading(completedFiles: 0, totalFiles: 0), rawFraction: 0.9).downloadFraction
               .map { String($0) } ?? "nil", "1.0", "clamped at 1")
        expect(ModelLoadProgress(phase: .compiling, rawFraction: 0.75).downloadFraction.map { String($0) } ?? "nil", "nil",
               "compiling has no fraction to show (the bar goes indeterminate, never parks at 50 %)")
    }

    static func modelFolderTests() {
        print("\n2.5 — model on disk")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SpeechModels.folder(.unified, in: root)!
        expect(SpeechModels.isDownloaded(.unified, in: root) ? "yes" : "no", "no", "absent folder → not downloaded")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Encoder.mlmodelc"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Encoder.mlmodelc/weight.bin").path, contents: Data(count: 1000))
        expect(SpeechModels.isDownloaded(.unified, in: root) ? "yes" : "no", "yes", "a compiled model present → downloaded")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Decoder.mlmodelc.partial").path, contents: Data(count: 500))
        expect(SpeechModels.isDownloaded(.unified, in: root) ? "yes" : "no", "no", "a .partial file → still downloading, not done")
        expect(String(SpeechModels.bytesOnDisk(.unified, in: root)), "1500", "bytes on disk include the partial")
        expect(SpeechModels.folderName(.apple) == nil ? "none" : "folder", "none", "Apple's model is the OS's, no folder")
    }

    static func installerTests() {
        print("\n2.5 — Install Command Line Tool (symlink, never clobber, no sudo)")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("spiel-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Spiel.app")
        let helper = CommandLineInstaller.helper(in: app)
        expect(helper.path.hasSuffix("Spiel.app/Contents/Helpers/spiel") ? "ok" : helper.path, "ok",
               "helper lives in Contents/Helpers (Contents/MacOS/spiel IS Contents/MacOS/Spiel on APFS)")
        let bin = root.appendingPathComponent("home/.local/bin")
        // Case names, not descriptions: the descriptions are prose for the user.
        func outcome(_ h: URL, _ d: URL) -> String {
            do { return "\(try CommandLineInstaller.install(helper: h, into: d))" }
            catch let e as CommandLineInstaller.InstallError {
                switch e {
                case .helperMissing: return "error: helperMissing"
                case .translocated: return "error: translocated"
                case .occupied: return "error: occupied"
                case .cannotCreate(let why): return "error: cannotCreate \(why)"
                }
            } catch { return "error: \(error)" }
        }
        expect(outcome(helper, bin) == "error: helperMissing" ? "refused" : outcome(helper, bin), "refused",
               "no helper in the bundle → refused, nothing linked")
        try? fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        expect(outcome(helper, bin).hasPrefix("installed") ? "installed" : outcome(helper, bin), "installed", "installs, creating ~/.local/bin")
        expect((try? fm.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("spiel").path)) ?? "none", helper.path, "…as a symlink to the helper")
        expect(outcome(helper, bin).hasPrefix("alreadyInstalled") ? "same" : "changed", "same", "a second install is a no-op")
        let old = root.appendingPathComponent("Old/Spiel.app/Contents/Helpers/spiel")
        try? fm.removeItem(at: bin.appendingPathComponent("spiel"))
        try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("spiel").path, withDestinationPath: old.path)
        expect(outcome(helper, bin).hasPrefix("replaced") ? "replaced" : "kept", "replaced", "a link to another copy of Spiel is updated")
        try? fm.removeItem(at: bin.appendingPathComponent("spiel"))
        try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("spiel").path, withDestinationPath: "/opt/other/spiel")
        expect(outcome(helper, bin).contains("occupied") ? "refused" : "clobbered", "refused", "a link to some OTHER spiel is left alone")
        try? fm.removeItem(at: bin.appendingPathComponent("spiel"))
        fm.createFile(atPath: bin.appendingPathComponent("spiel").path, contents: Data("mine".utf8))
        expect(outcome(helper, bin).contains("occupied") ? "refused" : "clobbered", "refused", "a regular file there is never overwritten")
        expect((try? String(contentsOf: bin.appendingPathComponent("spiel"), encoding: .utf8)) ?? "", "mine", "…and its contents are untouched")
        let trans = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Spiel.app/Contents/Helpers/spiel")
        expect(outcome(trans, bin) == "error: translocated" ? "refused" : outcome(trans, bin), "refused",
               "a translocated (read-only, random-path) app is refused with how to fix it")

        let home = fm.homeDirectoryForCurrentUser.path
        let ub = URL(fileURLWithPath: home + "/.local/bin")
        expect(CommandLineInstaller.isOnPath(ub, path: "/usr/bin:\(home)/.local/bin/:/bin") ? "yes" : "no", "yes", "PATH match tolerates a trailing slash")
        expect(CommandLineInstaller.isOnPath(ub, path: "/usr/bin:~/.local/bin") ? "yes" : "no", "yes", "…and a ~ spelling")
        expect(CommandLineInstaller.isOnPath(ub, path: "/usr/bin:\(home)/.local/binx") ? "yes" : "no", "no", "…but not a prefix")
    }

    static func listenListingTests() {
        print("\n2.5 — spiel transcripts: listing and picking")
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("spiel-tx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = TranscriptDocument()
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let fmt = TranscriptDocument.Frontmatter(title: "Board: Q3", startedAt: started, endedAt: started.addingTimeInterval(600),
                                                version: "2.5.0", inputDevice: "Yeti", engine: "e")
        try? doc.render(frontmatter: fmt).write(to: folder.appendingPathComponent("2026-09-25 1400 Board- Q3.md"), atomically: true, encoding: .utf8)
        try? "no frontmatter\n".write(to: folder.appendingPathComponent("2026-09-20 0930 Weekly.md"), atomically: true, encoding: .utf8)
        try? "x".write(to: folder.appendingPathComponent(".2026-09-26 0000 hidden.md.123.tmp"), atomically: true, encoding: .utf8)
        let items = (try? ListenTranscripts.list(in: folder)) ?? []
        expect(items.map { "\($0.number):\($0.name)" }.joined(separator: " | "),
               "1:2026-09-25 1400 Board- Q3.md | 2:2026-09-20 0930 Weekly.md", "newest first, numbered from 1, temp files skipped")
        expect(items.first.map { "\($0.title) \($0.durationSeconds ?? -1)" } ?? "", "Board: Q3 600", "title and duration from the frontmatter")
        expect(items.last?.title ?? "", "2026-09-20 0930 Weekly", "no frontmatter → the name is the title")
        func pick(_ r: String) -> String {
            let (i, c) = ListenTranscripts.resolve(r, in: items)
            return i.map { "\($0.number)" } ?? (c.isEmpty ? "none" : "ambiguous \(c.count)")
        }
        expect(pick("2"), "2", "a number picks by position")
        expect(pick("board"), "1", "a unique name fragment, any case")
        expect(pick("2026"), "ambiguous 2", "'2026' is a fragment of every name, not transcript #2026")
        expect(pick("2026-09-20 0930 Weekly"), "2", "exact name without .md")
        expect(pick("zzz"), "none", "no match")
    }

    // MARK: Files through the real pipeline

    /// Writes 16 kHz mono float samples as a WAV — the file the reader must read back.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioCapture.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }

    static func fileTranscriberTests() async {
        print("\n2.5 — spiel transcribe: a long file through the real segmenter (stub VAD + engine)")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("spiel-ft-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 30.5 s: a 20 s monologue (forces a 14 s length-cap split), a 4.25 s pause,
        // two 2 s bursts 1 s apart. Longer than FluidAudio's 15 s single-call limit on
        // purpose. Speech at 1–21, 25.25–27.25, 28.25–30.25.
        let audio = burst(speech: 20, pad: 1) + silence(3) + burst(speech: 2, pad: 0.25) + silence(0.5) + burst(speech: 2, pad: 0.25)
        let wav = dir.appendingPathComponent("long.wav")
        do { try writeWAV(audio, to: wav) } catch { expect("\(error)", "written", "fixture WAV written"); return }

        let transcriber = CountingTranscriber()
        let session = DictationSession(transcriber: transcriber, vad: EnergyVAD())
        try? await session.prepare()
        guard let out = try? await FileTranscriber.run(wav, displayName: "long.wav", engine: "stub", session: session) else {
            expect("threw", "ran", "FileTranscriber.run on a 30 s WAV"); return
        }
        let t = out.transcript
        expect(String(format: "%.1f", t.durationSeconds), String(format: "%.1f", Double(audio.count) / AudioCapture.sampleRate),
               "duration = every sample read back (16-bit WAV → 16 kHz float via AVAssetReader)")
        expectInt(t.segments.count, 4, "20 s monologue split at the 14 s cap + 2 bursts = 4 segments")
        let starts = t.segments.map(\.start), ends = t.segments.map(\.end)
        let monotonic = zip(starts, ends).allSatisfy { $0 <= $1 } && zip(ends, starts.dropFirst()).allSatisfy { $0 <= $1 }
        expect(monotonic ? "ok" : "\(t.segments)", "ok", "timestamps monotonic: start ≤ end ≤ next start")
        let frame = DictationSession.vadFrameSeconds + 0.001
        if t.segments.count == 4 {
            expect(abs(t.segments[0].start - 1.0) <= frame ? "ok" : "\(t.segments[0].start)", "ok", "first segment starts at the speech onset (1 s)")
            expect(abs(t.segments[1].end - 21.0) <= frame ? "ok" : "\(t.segments[1].end)", "ok",
                   "the cap-split tail ends where the monologue ends (21 s), not at the close")
            expect(t.segments[1].start > t.segments[0].start + 9 && t.segments[1].start <= t.segments[0].end + frame ? "ok" : "\(t.segments[0]) \(t.segments[1])", "ok",
                   "the split point is inside the monologue, and segment 1 ends where segment 2 starts")
            expect(abs(t.segments[3].end - (t.durationSeconds - 0.25)) <= frame ? "ok" : "\(t.segments[3].end)", "ok",
                   "the last segment (closed by finish, not silence) ends at its last speech")
        }
        expectInt(t.paragraphs.count, 2, "the 3 s pause makes a new paragraph; the 1 s pause does not")
        let second = try? await FileTranscriber.run(wav, displayName: "long.wav", engine: "stub", session: session)
        expect(second.map { "\($0.transcript.segments.count)" } ?? "threw", "4", "the same session transcribes a second file (reset re-arms)")

        let silent = dir.appendingPathComponent("silent.wav")
        try? writeWAV(silence(3), to: silent)
        let s = try? await FileTranscriber.run(silent, displayName: "silent.wav", engine: "stub", session: session)
        expect(s.map { "\($0.transcript.text.isEmpty) \($0.diagnosis.contains("silence"))" } ?? "threw", "true true", "a silent file: no text, diagnosed as silence")

        func readError(_ url: URL) async -> String {
            do { _ = try await FileTranscriber.run(url, displayName: "x", engine: "stub", session: session); return "read" }
            catch let e as AudioFileReader.ReadError { return "\(e)".components(separatedBy: ":")[0] }
            catch { return "other: \(error)" }
        }
        expect(await readError(dir.appendingPathComponent("nope.wav")), "no such file", "missing file → ReadError.missing (exit 2)")
        let bogus = dir.appendingPathComponent("bogus.m4a")
        try? "not audio".write(to: bogus, atomically: true, encoding: .utf8)
        expect(await readError(bogus), "cannot read audio", "garbage with an audio extension → ReadError.unreadable (exit 2)")
        expect(await readError(dir), "no such file", "a folder is not a file")
    }

    // MARK: App source rules

    static func appSourceRules25() {
        print("\n2.5 — app-source rules (setup window folded into the launch path)")
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var root: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/SpielApp/main.swift").path) { root = dir; break }
            dir.deleteLastPathComponent()
        }
        guard let root, let src = try? String(contentsOf: root.appendingPathComponent("Sources/SpielApp/main.swift"), encoding: .utf8),
              let bundle = try? String(contentsOf: root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8) else {
            print("  – SKIPPED: sources not found beside this binary (nothing asserted)")
            return
        }
        let code = src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        // Up to the NEAREST next declaration, whichever kind it is.
        func body(_ name: String) -> String {
            guard let start = code.range(of: "func \(name)(") else { return "" }
            let rest = code[start.upperBound...]
            let ends = ["\n    fileprivate func ", "\n    private func ", "\n    @objc ", "\n    func ", "\n    static func "]
                .compactMap { rest.range(of: $0)?.lowerBound }
            return String(rest[..<(ends.min() ?? rest.endIndex)])
        }
        let launch = body("applicationDidFinishLaunching")
        expect(launch.contains("decideSetupAtLaunch") ? "ok" : "missing", "ok", "launch goes through the setup decision")
        let direct = ["Notifier.requestAuthorization()", "requestMicrophoneAccess", "requestAccessibilityPermission"].filter { launch.contains($0) }
        expect(direct.isEmpty ? "none" : direct.joined(separator: ","), "none",
               "no permission prompt fires straight from launch (it would duplicate the window's buttons)")
        let decide = body("decideSetupAtLaunch")
        let caseShow: String = {
            guard let a = decide.range(of: "case .show:"), let b = decide.range(of: "case .markDone:"), a.upperBound < b.lowerBound else { return "" }
            return String(decide[a.upperBound..<b.lowerBound])
        }()
        expect(caseShow.contains("requestPermissionsAtLaunch") ? "prompts" : "window only", "window only",
               "first run: the window asks, no system prompts on top of it")
        expect(String(decide.components(separatedBy: "requestPermissionsAtLaunch()").count - 1), "2",
               "markDone and skip both keep the pre-2.5 launch-time requests (ask at launch, never on first use)")
        let closed = body("setupClosed")
        expect(closed.contains("foldPermissionsAfterSetup") && closed.contains("setupShownAtLaunch") ? "ok" : "missing", "ok",
               "closing a launch-opened window asks for whatever is still unanswered")
        expect(body("foldPermissionsAfterSetup").contains("requestAccessibilityPermission") ? "re-prompts" : "no", "no",
               "…without re-prompting Accessibility he just walked past (the menu keeps its ⚠︎)")
        expect(bundle.contains("cp \"$TOOL\" \"$APP/Contents/Helpers/spiel\"") && !bundle.contains("cp \"$TOOL\" \"$APP/Contents/MacOS") ? "ok" : "wrong place", "ok",
               "bundle.sh ships the tool in Contents/Helpers")
        expect(bundle.contains("Version.swift") && !bundle.contains("<string>2.") ? "ok" : "hardcoded", "ok",
               "bundle.sh reads the version from Version.swift (one source of truth)")
    }
}

extension ToolArguments.Exit {
    static var allRaw: String {
        [ToolArguments.Exit.ok, .usage, .unreadable, .engine, .noSpeech].map { String($0.rawValue) }.joined(separator: " ")
    }
}
