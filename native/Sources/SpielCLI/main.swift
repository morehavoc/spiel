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
      spiel-cli live [--seconds N] [--engine parakeet|apple]

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

case "doctor":
    print("spiel doctor")
    print("  macOS                  : \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("  SpeechAnalyzer (26+)   : \(AppleSpeechTranscriber.isAvailable ? "available" : "NOT available")")
    print("  Accessibility granted  : \(TextInserter.hasAccessibilityPermission())")
    print("  Secure Input active    : \(TextInserter.isSecureInputEnabled())")
    print("  Glossary terms         : \(Glossary().count) aliases")
    exit(0)

case "glossary":
    guard args.count > 1 else { usage() }
    let input = args[1]
    print(Glossary().apply(to: input))
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

    Task {
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
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        defer { semaphore.signal() }
        do {
            let transcriber = makeTranscriber(args)
            let session = DictationSession(transcriber: transcriber)
            print("preparing \(transcriber.kind.rawValue) + Silero VAD…")
            try await session.prepare()

            await session.setEventHandler { event in
                switch event {
                case .speechStarted: print("  [speech]")
                case .segmentCaptured(let i, let s):
                    print("  [segment \(i): \(String(format: "%.2f", s))s]")
                case .textReleased(let t): print("  > \(t)")
                case .error(let e): print("  ! \(e)")
                case .levels: break
                }
            }

            let capture = AudioCapture()
            print("listening for \(Int(seconds))s — speak now")
            try capture.start { samples in
                Task { await session.feed(samples) }
            }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            capture.stop()
            let text = await session.finish()
            print("\nTRANSCRIPT: \(text.isEmpty ? "(nothing captured)" : text)")
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
