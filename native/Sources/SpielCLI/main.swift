import Foundation
import SpielCore
import FluidAudio

// A headless harness for SpielCore. It exists so transcription can be proven without
// a GUI, without the microphone, and without anyone present to click a TCC prompt --
// file in, text out, timing printed.

func usage() -> Never {
    FileHandle.standardError.write("""
    spiel-cli — headless harness for SpielCore

      spiel-cli transcribe <audiofile> [--engine parakeet|apple] [--no-glossary]
      spiel-cli glossary "<text>"
      spiel-cli doctor
      spiel-cli selftest
      spiel-cli live [--seconds N] [--rounds N] [--engine parakeet|apple]
          --rounds runs N consecutive dictations on ONE session, which is what the
          app does across hotkey presses. Round 2 is the one that used to go deaf.

    """.data(using: .utf8)!)
    exit(2)
}

func arg(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func makeTranscriber(_ args: [String]) -> any Transcriber {
    let name = arg("--engine", in: args) ?? "parakeet"
    switch name {
    case "apple": return AppleSpeechTranscriber()
    default: return ParakeetTranscriber()
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {

case "selftest":
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached { code = await SelfTest.run(); sem.signal() }
    sem.wait()
    exit(code)

case "doctor":
    print("spiel doctor")
    print("  macOS                  : \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("  SpeechAnalyzer (26+)   : \(AppleSpeechTranscriber.isAvailable ? "available" : "NOT available")")
    print("  Accessibility granted  : \(TextInserter.hasAccessibilityPermission())")
    let secure = TextInserter.isSecureInputEnabled()
    print("  Secure Input active    : \(secure)\(secure ? " — held by \(TextInserter.secureInputHolder() ?? "unknown")" : "")")
    print("  Microphone permission  : \(AudioCapture.microphoneAuthorization().rawValue)")
    print("  Default input device   : \(AudioCapture.defaultInputDeviceName())")
    print("  Glossary terms         : \(Glossary.load().count) aliases (built-in \(Glossary().count))")
    print("  Vocabulary file        : \(Glossary.userFileURL.path)\(FileManager.default.fileExists(atPath: Glossary.userFileURL.path) ? "" : " (not created yet — Edit Vocabulary… in the app menu)")")
    print("  App log                : \(DiagnosticLog.url.path)")
    exit(0)

case "glossary":
    guard args.count > 1 else { usage() }
    let input = args[1]
    print(Glossary.load().apply(to: input))
    exit(0)

case "transcribe":
    guard args.count > 1 else { usage() }
    let path = args[1]
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write("no such file: \(path)\n".data(using: .utf8)!)
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task.detached {
        defer { semaphore.signal() }
        do {
            let samples = try AudioCapture.loadFile(at: url)
            let audioSeconds = Double(samples.count) / AudioCapture.sampleRate
            print("file          : \(url.lastPathComponent)")
            print("audio         : \(String(format: "%.2f", audioSeconds))s @ 16kHz mono (\(samples.count) samples)")

            let transcriber = makeTranscriber(args)
            print("engine        : \(transcriber.kind.rawValue)")

            let loadStart = Date()
            try await transcriber.prepare()
            print("model load    : \(String(format: "%.0f", Date().timeIntervalSince(loadStart) * 1000))ms")

            let start = Date()
            let raw = try await transcriber.transcribe(samples: samples)
            let wall = Date().timeIntervalSince(start)

            let useGlossary = !args.contains("--no-glossary")
            let final = useGlossary ? Glossary().apply(to: raw) : raw

            print("wall clock    : \(String(format: "%.0f", wall * 1000))ms")
            print("realtime factor: \(String(format: "%.1f", audioSeconds / max(wall, 0.0001)))x")
            print("raw           : \(raw)")
            if useGlossary && final != raw {
                print("glossary      : \(final)")
            }
        } catch {
            FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    semaphore.wait()
    exit(exitCode)

case "live":
    let seconds = Double(arg("--seconds", in: args) ?? "6") ?? 6
    let rounds = Int(arg("--rounds", in: args) ?? "1") ?? 1
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task.detached {
        defer { semaphore.signal() }
        do {
            let transcriber = makeTranscriber(args)
            let session = DictationSession(transcriber: transcriber)
            print("preparing \(transcriber.kind.rawValue) + Silero VAD…")
            try await session.prepare()
            print("microphone permission: \(AudioCapture.microphoneAuthorization().rawValue); input: \(AudioCapture.defaultInputDeviceName())")

            await session.setEventHandler { event in
                switch event {
                case .speechStarted: print("  [speech]")
                case .segmentCaptured(let i, let s):
                    print("  [segment \(i): \(String(format: "%.2f", s))s]")
                case .textReleased(let t): print("  > \(t)")
                case .error(let e): print("  ! \(e)")
                }
            }

            for round in 1...max(rounds, 1) {
                // Same sequence as the app: reset (re-arm) → start mic → stop → finish.
                await session.reset()
                let capture = AudioCapture()
                print("\nround \(round)/\(rounds): listening for \(Int(seconds))s — speak now")
                // Synchronous, ordered handoff — NOT `Task { await feed(...) }`, whose
                // execution order is not guaranteed and would shuffle mic buffers.
                try capture.start { samples in
                    session.sink.submit(samples)
                }
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                capture.stop()
                let report = await session.finishWithReport()
                print("  audio \(String(format: "%.2f", report.audioSeconds))s, peak \(String(format: "%.3f", report.peak)), segments \(report.segments), dropped buffers \(report.droppedBuffers)")
                print("  diagnosis: \(report.diagnosis)")
                print("  TRANSCRIPT: \(report.text.isEmpty ? "(nothing captured)" : report.text)")
                if report.droppedBuffers > 0 { exitCode = 3 }
            }
        } catch {
            FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    semaphore.wait()
    exit(exitCode)

default:
    usage()
}
