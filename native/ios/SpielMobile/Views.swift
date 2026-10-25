import AVFoundation
import SwiftUI
import UIKit

@main
struct SpielMobileApp: App {
    @StateObject private var model = ListenModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack { LiveView() }
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.cyan)
        }
    }
}

/// Transcript text size, shared by the live and saved views. 21 pt default —
/// readable on a phone lying on a meeting table.
enum TextSize {
    static let key = "transcriptTextSize"
    static let range: ClosedRange<Double> = 16...32
    static let standard: Double = 21
}

/// A transcript line as the views show it: live paragraphs and saved files both
/// reduce to this.
struct Line: Identifiable, Equatable {
    let id: Int
    let stamp: String?
    let seconds: TimeInterval?
    let text: String
    let isMarker: Bool
}

extension TranscriptDocument {
    var lines: [Line] {
        paragraphs.enumerated().map { i, p in
            Line(id: i, stamp: p.isMarker ? nil : TranscriptDocument.formatOffset(p.offset),
                 seconds: p.isMarker ? nil : p.offset, text: p.text, isMarker: p.isMarker)
        }
    }
}

/// Parses a saved transcript body (`[MM:SS] text` paragraphs, blank-line separated).
func lines(fromBody body: String) -> [Line] {
    body.components(separatedBy: "\n\n").enumerated().compactMap { i, raw in
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let inside = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if inside.allSatisfy({ $0.isNumber || $0 == ":" }), !rest.isEmpty {
                let parts = inside.split(separator: ":").compactMap { Double($0) }
                let secs = parts.reduce(0) { $0 * 60 + $1 }
                return Line(id: i, stamp: inside, seconds: secs, text: rest, isMarker: false)
            }
            return Line(id: i, stamp: nil, seconds: nil, text: s, isMarker: true)
        }
        return Line(id: i, stamp: nil, seconds: nil, text: s, isMarker: false)
    }
}

// MARK: - Transcript list (shared by live and saved)

struct TranscriptList: View {
    let lines: [Line]
    let query: String
    /// Live only: keep the newest line in view unless he has scrolled up.
    var follow: Binding<Bool>? = nil
    var revision: Int = 0
    @Binding var jumpTo: Int?
    /// Saved transcripts with audio: tapping a timestamp plays from there.
    var onStamp: ((TimeInterval) -> Void)? = nil
    @AppStorage(TextSize.key) private var size = TextSize.standard

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if shown.isEmpty && !query.isEmpty {
                        Text("No matches for “\(query)”").foregroundStyle(Theme.dim).padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(shown) { line in
                        LineView(line: line, query: query, size: size,
                                 isNewest: follow != nil && line.id == lines.last?.id, onStamp: onStamp)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Tapping a search hit jumps to it in the full transcript.
                                if !query.isEmpty { jumpTo = line.id }
                            }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { follow?.wrappedValue = true }
                        .onDisappear { if follow != nil, !lines.isEmpty { follow?.wrappedValue = false } }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .onChange(of: revision) {
                if query.isEmpty, follow?.wrappedValue == true {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            // A tapped hit clears the search (the parent does that); once the full
            // transcript is back, scroll to the line that was tapped.
            .onChange(of: query) {
                guard query.isEmpty, let id = jumpTo else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    jumpTo = nil
                }
            }
            .overlay(alignment: .bottom) {
                if let follow, !follow.wrappedValue, query.isEmpty {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Back to live", systemImage: "arrow.down")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Theme.wave, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    }
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var shown: [Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}

struct LineView: View {
    let line: Line
    let query: String
    let size: Double
    var isNewest = false
    var onStamp: ((TimeInterval) -> Void)? = nil

    var body: some View {
        if line.isMarker {
            Text(line.text)
                .font(.system(size: size * 0.7, design: .rounded))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
                .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let stamp = line.stamp {
                    if let onStamp, let s = line.seconds {
                        Button { onStamp(s) } label: {
                            Label(stamp, systemImage: "play.fill").labelStyle(StampLabel())
                        }
                    } else {
                        Text(stamp).modifier(StampStyle(size: size))
                    }
                }
                Text(highlighted)
                    .font(.system(size: size, weight: .regular, design: .rounded))
                    .lineSpacing(size * 0.28)
                    .foregroundStyle(Theme.ink.opacity(isNewest ? 1 : 0.86))
                    .textSelection(.enabled)
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule().fill(isNewest ? AnyShapeStyle(Theme.wave) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .frame(width: 3)
            }
            .animation(.easeOut(duration: 0.4), value: isNewest)
        }
    }

    private var highlighted: AttributedString {
        var a = AttributedString(line.text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var search = a.startIndex..<a.endIndex
        while let r = a[search].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Theme.violet.opacity(0.55)
            a[r].foregroundColor = .white
            search = r.upperBound..<a.endIndex
        }
        return a
    }
}

struct StampStyle: ViewModifier {
    var size: Double = TextSize.standard
    func body(content: Content) -> some View {
        content.font(.system(size: max(12, size * 0.6), weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.cyan)
    }
}

struct StampLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(Theme.cyan)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.cyan.opacity(0.12), in: Capsule())
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var model: ListenModel
    @State private var query = ""
    @State private var follow = true
    @State private var jumpTo: Int?
    @State private var toast: String?
    @State private var showNew = false
    @State private var askDownload = false
    @State private var askedDownload = false
    @State private var renaming = false
    @State private var newTitle = ""
    @AppStorage(TextSize.key) private var size = TextSize.standard

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.startedAt != nil { controls }
        }
        .themed()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SearchIf(enabled: model.startedAt != nil, query: $query))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { LibraryView() } label: { Image(systemName: "books.vertical") }
                    .accessibilityLabel("Transcripts")
            }
            ToolbarItem(placement: .principal) {
                if model.startedAt != nil {
                    VStack(spacing: 1) {
                        Text(model.title).font(.system(.headline, design: .rounded)).lineLimit(1)
                        HStack(spacing: 4) {
                            if let place = model.location {
                                Image(systemName: "mappin.and.ellipse"); Text(place).lineLimit(1)
                            } else if let s = model.startedAt {
                                Text(s, format: .dateTime.weekday().month().day().hour().minute())
                            }
                            if model.audioURL != nil { Image(systemName: "waveform") }
                        }
                        .font(.caption2).foregroundStyle(Theme.dim)
                    }
                    .onTapGesture { newTitle = model.title; renaming = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.startedAt != nil {
                        ExportItems(plain: model.doc.body(plain: true), timed: model.doc.body(),
                                    file: model.fileURL, audio: model.isActive ? nil : model.audioURL, toast: $toast)
                        Divider()
                        Button { newTitle = model.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    }
                    TextSizeItems(size: $size)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showNew) { NewMeetingSheet().environmentObject(model) }
        .alert("Download the speech model?", isPresented: $askDownload) {
            Button("Download Now") { model.downloadModel() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Spiel transcribes on this iPhone, so it needs its speech model first: a one-time download of about 600 MB. Wi-Fi is recommended. After that, Spiel works with no internet.")
        }
        .onAppear { if model.phase == .needsDownload && !askedDownload { askedDownload = true; askDownload = true } }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { if !newTitle.trimmingCharacters(in: .whitespaces).isEmpty { model.title = newTitle } }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .top) { Toast(text: $toast) }
        .onChange(of: jumpTo) { if jumpTo != nil { query = "" } }
        #if DEBUG
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["SPIEL_SHOW_NEW"] == "1" { showNew = true }
            if env["SPIEL_OPEN_LATEST"] == "1" { openLatest = SavedTranscript.all().first }
            if let q = env["SPIEL_QUERY"] { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { query = q } }
        }
        .navigationDestination(item: $openLatest) { SavedTranscriptView(item: $0) }
        #endif
    }

    #if DEBUG
    @State private var openLatest: SavedTranscript?
    #endif

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading(let text):
            VStack(spacing: 22) {
                WaveBars(level: 0.6, live: true, barWidth: 8, height: 70)
                Text(text).font(.system(.callout, design: .rounded)).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.dim).padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsDownload:
            HomeHero(onNew: { askDownload = true }, buttonTitle: "Download speech model", buttonIcon: "arrow.down.circle.fill",
                     note: "Spiel needs a one-time download of about 600 MB before it can listen. Wi-Fi recommended.")
        case .failed(let text):
            VStack(spacing: 18) {
                Text(text).foregroundStyle(Theme.record).multilineTextAlignment(.center)
                Button { model.downloadModel() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(GradientButtonStyle()).padding(.horizontal, 30)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.startedAt == nil {
                HomeHero(onNew: { showNew = true })
            } else if model.doc.isEmpty {
                VStack(spacing: 18) {
                    WaveBars(level: model.level, live: model.phase == .recording, barWidth: 8, height: 70)
                    Text(model.isActive ? "Listening. Words appear a moment after each pause." : "Nothing was heard.")
                        .font(.system(.callout, design: .rounded)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptList(lines: model.doc.lines, query: query, follow: $follow,
                               revision: model.revision, jumpTo: $jumpTo)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let err = model.lastError {
                Text(err).font(.footnote).foregroundStyle(Theme.record).multilineTextAlignment(.center)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(clock(model.elapsed(now: ctx.date)))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                    }
                    Text("\(model.doc.wordCount) words").font(.caption).foregroundStyle(Theme.dim)
                }
                .frame(width: 96, alignment: .leading)
                Spacer()
                if model.isActive {
                    RecordButton(recording: model.phase == .recording) { model.stop() }
                } else {
                    Button { showNew = true } label: {
                        Image(systemName: "plus").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 70, height: 70).background(Theme.wave, in: Circle())
                            .shadow(color: Theme.violet.opacity(0.4), radius: 12, y: 5)
                    }
                    .accessibilityLabel("New meeting")
                }
                Spacer()
                HStack(spacing: 14) {
                    if model.isActive {
                        WaveBars(level: model.level, live: model.phase == .recording, barWidth: 3, height: 26)
                        Button { model.phase == .paused ? model.resume() : model.pause() } label: {
                            Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                                .frame(width: 44, height: 44).background(Theme.card, in: Circle())
                        }
                        .accessibilityLabel(model.phase == .paused ? "Resume" : "Pause")
                    } else {
                        Text("Saved").font(.caption.weight(.semibold)).foregroundStyle(Theme.cyan)
                    }
                }
                .frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 6)
        .background(.ultraThinMaterial.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardStroke).frame(height: 1) }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SearchIf: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search this meeting")
        } else {
            content
        }
    }
}

struct RecordButton: View {
    let recording: Bool
    let stop: () -> Void
    @State private var pulse = false
    var body: some View {
        Button(action: stop) {
            ZStack {
                Circle().stroke(Theme.record.opacity(0.35), lineWidth: 6)
                    .scaleEffect(pulse && recording ? 1.18 : 1).opacity(pulse && recording ? 0 : 1)
                Circle().fill(Theme.record)
                RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 24, height: 24)
            }
            .frame(width: 70, height: 70)
            .shadow(color: Theme.record.opacity(0.45), radius: 12, y: 5)
        }
        .accessibilityLabel("Stop")
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

struct HomeHero: View {
    let onNew: () -> Void
    var buttonTitle = "New meeting"
    var buttonIcon = "mic.fill"
    var note: String?
    @State private var recent: [SavedTranscript] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 14) {
                    WaveBars(barWidth: 9, height: 84)
                        .padding(.vertical, 26).padding(.horizontal, 34)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .shadow(color: Theme.violet.opacity(0.35), radius: 30, y: 10)
                    Text("Spiel").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                    Text("Live transcripts of the room you're in.\nNothing leaves this iPhone.")
                        .font(.system(.callout, design: .rounded)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 30)
                Button(action: onNew) { Label(buttonTitle, systemImage: buttonIcon) }
                    .buttonStyle(GradientButtonStyle())
                    .padding(.horizontal, 30)
                if let note {
                    Text(note).font(.footnote).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RECENT").font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).tracking(1.2)
                        ForEach(recent.prefix(4)) { item in
                            NavigationLink { SavedTranscriptView(item: item) } label: { TranscriptCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 30)
        }
        .onAppear { recent = SavedTranscript.all() }
    }
}

// MARK: - New meeting

struct NewMeetingSheet: View {
    @EnvironmentObject var model: ListenModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ctx = MeetingContext()

    enum Choice: Hashable { case meeting(MeetingContext.Meeting), dateTime, custom }
    @State private var choice: Choice = .dateTime
    @State private var custom = ""
    @AppStorage("addLocation") private var addLocation = false
    @AppStorage("keepAudio") private var keepAudio = false
    @State private var now = Date()
    @FocusState private var customFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("TITLE") {
                        VStack(spacing: 10) {
                            ForEach(ctx.meetings) { m in
                                option(.meeting(m), icon: "calendar", title: m.title,
                                       detail: "\(m.start.formatted(date: .omitted, time: .shortened)) – \(m.end.formatted(date: .omitted, time: .shortened))\(m.location.map { " · \($0)" } ?? "")",
                                       dot: m.calendarColor.map { Color(cgColor: $0) })
                            }
                            if let note = ctx.calendarNote, ctx.meetings.isEmpty {
                                Text(note).font(.footnote).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                            }
                            option(.dateTime, icon: "clock", title: ListenModel.dateTitle(now), detail: "Date and time")
                            HStack(spacing: 12) {
                                Image(systemName: "pencil").frame(width: 22).foregroundStyle(Theme.cyan)
                                TextField("Custom title", text: $custom)
                                    .focused($customFocused)
                                    .font(.system(.body, design: .rounded))
                                    .submitLabel(.done)
                                    .onChange(of: customFocused) { if customFocused { choice = .custom } }
                            }
                            .card(padding: 14, radius: 14)
                            .overlay(selectedRing(choice == .custom))
                        }
                    }
                    section("OPTIONS") {
                        VStack(spacing: 10) {
                            Toggle(isOn: $addLocation) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Add location", systemImage: "mappin.and.ellipse")
                                    if addLocation {
                                        Text(locationText).font(.caption).foregroundStyle(Theme.dim)
                                    }
                                }
                            }
                            .card(padding: 14, radius: 14)
                            Toggle(isOn: $keepAudio) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Keep audio", systemImage: "waveform")
                                    Text("Saved with the transcript, about 14 MB an hour.").font(.caption).foregroundStyle(Theme.dim)
                                }
                            }
                            .card(padding: 14, radius: 14)
                        }
                        .tint(Theme.violet)
                    }
                }
                .padding(20)
            }
            .themed()
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.start(title: chosenTitle, location: addLocation ? chosenLocation : nil, keepAudio: keepAudio)
                    dismiss()
                } label: { Label("Start listening", systemImage: "mic.fill") }
                .buttonStyle(GradientButtonStyle())
                .disabled(choice == .custom && custom.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .navigationTitle("New meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.navyBottom)
        .task {
            now = Date()
            await ctx.loadMeetings(now: now)
            if let first = ctx.meetings.first, choice == .dateTime { choice = .meeting(first) }
            if addLocation { ctx.locate() }
        }
        .onChange(of: addLocation) { if addLocation, ctx.place == nil { ctx.locate() } }
    }

    private var chosenTitle: String {
        switch choice {
        case .meeting(let m): return m.title
        case .dateTime: return ListenModel.dateTitle(now)
        case .custom: return custom.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The calendar event's own location wins (it names the room); else where the phone is.
    private var chosenLocation: String? {
        if case .meeting(let m) = choice, let l = m.location { return l }
        return ctx.place
    }

    private var locationText: String {
        if case .meeting(let m) = choice, let l = m.location { return "\(l) (from the calendar)" }
        if let p = ctx.place { return p }
        if ctx.locating { return "Finding where you are…" }
        return ctx.locationNote ?? "Location unavailable"
    }

    private func section<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).tracking(1.2)
            c()
        }
    }

    private func option(_ c: Choice, icon: String, title: String, detail: String, dot: Color? = nil) -> some View {
        Button {
            choice = c
            customFocused = false
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.cyan)
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7).offset(x: 3, y: 3) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body, design: .rounded).weight(.semibold)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Text(detail).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                if choice == c { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.wave) }
            }
            .card(padding: 14, radius: 14)
            .overlay(selectedRing(choice == c))
        }
        .buttonStyle(.plain)
    }

    private func selectedRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(on ? AnyShapeStyle(Theme.wave) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
    }
}

// MARK: - Export, text size, toast

struct ExportItems: View {
    let plain: String
    let timed: String
    let file: URL?
    let audio: URL?
    @Binding var toast: String?

    var body: some View {
        Button { UIPasteboard.general.string = plain; toast = "Copied" } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        Button { UIPasteboard.general.string = timed; toast = "Copied with timestamps" } label: {
            Label("Copy with timestamps", systemImage: "clock")
        }
        ShareLink(item: timed) { Label("Share text…", systemImage: "square.and.arrow.up") }
        if let file {
            ShareLink(item: file) { Label("Share Markdown file…", systemImage: "doc.richtext") }
        }
        if let audio, FileManager.default.fileExists(atPath: audio.path) {
            ShareLink(item: audio) { Label("Share audio…", systemImage: "waveform") }
        }
    }
}

struct TextSizeItems: View {
    @Binding var size: Double
    var body: some View {
        Section("Text size") {
            Button { size = min(TextSize.range.upperBound, size + 2) } label: { Label("Larger", systemImage: "textformat.size.larger") }
            Button { size = max(TextSize.range.lowerBound, size - 2) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
        }
    }
}

struct Toast: View {
    @Binding var text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation { self.text = nil }
                }
        }
    }
}

// MARK: - Library

struct SavedTranscript: Identifiable, Hashable {
    let url: URL
    let title: String
    let date: Date
    let location: String?
    let duration: TimeInterval?
    let words: Int?
    let audio: URL?
    var id: URL { url }

    static func all() -> [SavedTranscript] {
        let folder = TranscriptStore.defaultFolder
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "md" }.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let f = TranscriptDocument.parseFrontmatter(text)?.fields ?? [:]
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let started = f["started"].flatMap { ISO8601DateFormatter().date(from: $0) }
            let audio = f["audio"].map { folder.appendingPathComponent($0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            return SavedTranscript(url: url, title: f["title"] ?? url.deletingPathExtension().lastPathComponent,
                                   date: started ?? modified, location: f["location"],
                                   duration: f["duration_s"].flatMap(Double.init), words: f["words"].flatMap(Int.init),
                                   audio: audio)
        }.sorted { $0.date > $1.date }
    }
}

struct TranscriptCard: View {
    let item: SavedTranscript
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.wave).frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink).lineLimit(2)
                HStack(spacing: 10) {
                    Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if let d = item.duration { Text(TranscriptDocument.formatDuration(d)) }
                    if let w = item.words { Text("\(w) words") }
                }
                .font(.caption).foregroundStyle(Theme.dim)
                if let l = item.location {
                    Label(l, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            Spacer()
            if item.audio != nil { Image(systemName: "waveform").foregroundStyle(Theme.cyan) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.dim)
        }
        .card(padding: 14, radius: 16)
    }
}

struct LibraryView: View {
    @State private var items: [SavedTranscript] = []
    @State private var query = ""

    var body: some View {
        List {
            ForEach(filtered) { item in
                NavigationLink { SavedTranscriptView(item: item) } label: { TranscriptCard(item: item) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
            .onDelete { idx in
                for i in idx {
                    try? FileManager.default.removeItem(at: filtered[i].url)
                    if let a = filtered[i].audio { try? FileManager.default.removeItem(at: a) }
                }
                items = SavedTranscript.all()
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty { Text("No transcripts yet.").foregroundStyle(Theme.dim) }
        }
        .themed()
        .searchable(text: $query, prompt: "Search all transcripts")
        .navigationTitle("Transcripts")
        .onAppear { items = SavedTranscript.all() }
    }

    /// Searches titles, places AND full text, so "budget" finds the meeting.
    private var filtered: [SavedTranscript] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(q)
                || (item.location?.localizedCaseInsensitiveContains(q) ?? false)
                || ((try? String(contentsOf: item.url, encoding: .utf8))?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

struct SavedTranscriptView: View {
    let item: SavedTranscript
    @State private var query = ""
    @State private var jumpTo: Int?
    @State private var toast: String?
    @State private var text = ""
    @StateObject private var player = Player()
    @AppStorage(TextSize.key) private var size = TextSize.standard

    var body: some View {
        let all = lines(fromBody: text)
        VStack(spacing: 0) {
            TranscriptList(lines: all, query: query, jumpTo: $jumpTo,
                           onStamp: item.audio == nil ? nil : { player.play(at: $0) })
            if let audio = item.audio { PlayerBar(player: player, url: audio) }
        }
        .themed()
        .onChange(of: jumpTo) { if jumpTo != nil { query = "" } }
        .searchable(text: $query, prompt: "Search this meeting")
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ExportItems(plain: all.filter { !$0.isMarker }.map(\.text).joined(separator: "\n\n"),
                                timed: text, file: item.url, audio: item.audio, toast: $toast)
                    TextSizeItems(size: $size)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .overlay(alignment: .top) { Toast(text: $toast) }
        .onAppear {
            let raw = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            text = TranscriptDocument.parseFrontmatter(raw)?.body ?? raw
            if let a = item.audio { player.load(a) }
        }
        .onDisappear { player.stop() }
    }
}

// MARK: - Audio playback

@MainActor
final class Player: ObservableObject {
    @Published var playing = false
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var p: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        p = try? AVAudioPlayer(contentsOf: url)
        p?.prepareToPlay()
        duration = p?.duration ?? 0
    }
    func play(at t: TimeInterval? = nil) {
        guard let p else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let t { p.currentTime = min(max(0, t), p.duration) }
        p.play(); playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.time = self.p?.currentTime ?? 0
                if self.p?.isPlaying == false { self.playing = false }
            }
        }
    }
    func toggle() { playing ? pause() : play() }
    func pause() { p?.pause(); playing = false }
    func seek(_ t: TimeInterval) { p?.currentTime = t; time = t }
    func stop() { p?.stop(); playing = false; timer?.invalidate() }
}

struct PlayerBar: View {
    @ObservedObject var player: Player
    let url: URL
    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(Theme.wave, in: Circle())
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            VStack(spacing: 4) {
                Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                HStack {
                    Text(TranscriptDocument.formatOffset(player.time))
                    Spacer()
                    Text(TranscriptDocument.formatOffset(player.duration))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardStroke).frame(height: 1) }
    }
}
