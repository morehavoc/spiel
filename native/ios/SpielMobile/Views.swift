import SwiftUI
import UIKit

@main
struct SpielMobileApp: App {
    @StateObject private var model = ListenModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack { LiveView() }
                .environmentObject(model)
        }
    }
}

/// A transcript line as the views show it: live paragraphs and saved files both
/// reduce to this.
struct Line: Identifiable, Equatable {
    let id: Int
    let stamp: String?
    let text: String
    let isMarker: Bool
}

extension TranscriptDocument {
    var lines: [Line] {
        paragraphs.enumerated().map { i, p in
            Line(id: i, stamp: p.isMarker ? nil : TranscriptDocument.formatOffset(p.offset),
                 text: p.text, isMarker: p.isMarker)
        }
    }
}

/// Parses a saved transcript body (`[MM:SS] text` paragraphs, blank-line separated).
func lines(fromBody body: String) -> [Line] {
    body.components(separatedBy: "\n\n").enumerated().compactMap { i, raw in
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let inside = s[s.index(after: s.startIndex)..<close]
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if inside.allSatisfy({ $0.isNumber || $0 == ":" }), !rest.isEmpty {
                return Line(id: i, stamp: String(inside), text: rest, isMarker: false)
            }
            return Line(id: i, stamp: nil, text: s, isMarker: true)
        }
        return Line(id: i, stamp: nil, text: s, isMarker: false)
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(shown) { line in
                        LineView(line: line, query: query)
                            .id(line.id)
                            .onTapGesture {
                                // Tapping a search hit jumps to it in the full transcript.
                                if !query.isEmpty { jumpTo = line.id }
                            }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { follow?.wrappedValue = true }
                        .onDisappear { if follow != nil, !lines.isEmpty { follow?.wrappedValue = false } }
                }
                .padding()
            }
            .onChange(of: revision) {
                if query.isEmpty, follow?.wrappedValue == true {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
                        Label("Live", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
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
    var body: some View {
        if line.isMarker {
            Text(line.text).font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let stamp = line.stamp {
                    Text(stamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(highlighted).font(.body).textSelection(.enabled)
            }
        }
    }

    private var highlighted: AttributedString {
        var a = AttributedString(line.text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var search = a.startIndex..<a.endIndex
        while let r = a[search].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = .yellow.opacity(0.5)
            search = r.upperBound..<a.endIndex
        }
        return a
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var model: ListenModel
    @State private var query = ""
    @State private var follow = true
    @State private var jumpTo: Int?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            content
            controls
        }
        .navigationTitle(model.isActive || model.startedAt != nil ? (model.title.isEmpty ? "Untitled" : model.title) : "Spiel")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search transcript")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { LibraryView() } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Transcripts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ExportMenu(plain: model.doc.body(plain: true), timed: model.doc.body(), file: model.fileURL, copied: $copied)
                    .disabled(model.doc.isEmpty)
            }
        }
        .alert("Copied", isPresented: $copied) { Button("OK", role: .cancel) {} }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading(let text):
            VStack(spacing: 12) { ProgressView(); Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary) }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text):
            Text(text).foregroundStyle(.red).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.doc.isEmpty {
                VStack(spacing: 8) {
                    if model.isActive {
                        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Listening. Text appears a moment after each pause.").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Press Record and put the phone where it can hear the room. Everything stays on this iPhone.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptList(lines: model.doc.lines, query: query, follow: $follow,
                               revision: model.revision, jumpTo: $jumpTo)
                    .onChange(of: jumpTo) { if jumpTo != nil { query = "" } }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let err = model.lastError {
                Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if !model.isActive, model.phase == .ready {
                TextField("Title", text: $model.title).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(TranscriptDocument.formatDuration(model.elapsed(now: ctx.date)))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(minWidth: 60, alignment: .leading)
                Spacer()
                if model.isActive {
                    Button {
                        model.phase == .paused ? model.resume() : model.pause()
                    } label: {
                        Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill").font(.title2)
                    }
                    .accessibilityLabel(model.phase == .paused ? "Resume" : "Pause")
                    Button(role: .destructive) { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.red, in: Capsule()).foregroundStyle(.white)
                    }
                } else {
                    Button { model.start() } label: {
                        Label("Record", systemImage: "record.circle").font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(model.phase == .ready ? Color.accentColor : Color.gray, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(model.phase != .ready)
                }
                Spacer()
                Text("\(model.doc.wordCount) words").font(.subheadline).foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .padding()
        .background(.bar)
    }
}

// MARK: - Export

struct ExportMenu: View {
    let plain: String
    let timed: String
    let file: URL?
    @Binding var copied: Bool

    var body: some View {
        Menu {
            Button { UIPasteboard.general.string = plain; copied = true } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
            Button { UIPasteboard.general.string = timed; copied = true } label: {
                Label("Copy with timestamps", systemImage: "clock")
            }
            ShareLink(item: timed) { Label("Share text…", systemImage: "square.and.arrow.up") }
            if let file {
                ShareLink(item: file) { Label("Share Markdown file…", systemImage: "doc.richtext") }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Export")
    }
}

// MARK: - Library

struct SavedTranscript: Identifiable, Hashable {
    let url: URL
    let title: String
    let date: Date
    var id: URL { url }
}

struct LibraryView: View {
    @State private var items: [SavedTranscript] = []
    @State private var query = ""

    var body: some View {
        List {
            ForEach(filtered) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading) {
                        Text(item.title).font(.headline)
                        Text(item.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: filtered[i].url) }
                reload()
            }
        }
        .overlay { if items.isEmpty { Text("No transcripts yet.").foregroundStyle(.secondary) } }
        .searchable(text: $query, prompt: "Search all transcripts")
        .navigationTitle("Transcripts")
        .navigationDestination(for: SavedTranscript.self) { SavedTranscriptView(item: $0) }
        .onAppear(perform: reload)
    }

    /// Searches titles AND full text, so "what did we say about the budget" finds the meeting.
    private var filtered: [SavedTranscript] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(q)
                || ((try? String(contentsOf: item.url, encoding: .utf8))?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func reload() {
        let folder = TranscriptStore.defaultFolder
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        items = urls.filter { $0.pathExtension == "md" }.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let fields = TranscriptDocument.parseFrontmatter(text)?.fields ?? [:]
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let started = fields["started"].flatMap { ISO8601DateFormatter().date(from: $0) }
            return SavedTranscript(url: url, title: fields["title"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                                   ?? url.deletingPathExtension().lastPathComponent,
                                   date: started ?? date)
        }.sorted { $0.date > $1.date }
    }
}

struct SavedTranscriptView: View {
    let item: SavedTranscript
    @State private var query = ""
    @State private var jumpTo: Int?
    @State private var copied = false
    @State private var body_ = ""

    var body: some View {
        TranscriptList(lines: lines(fromBody: body_), query: query, jumpTo: $jumpTo)
            .onChange(of: jumpTo) { if jumpTo != nil { query = "" } }
            .searchable(text: $query, prompt: "Search transcript")
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportMenu(plain: lines(fromBody: body_).filter { !$0.isMarker }.map(\.text).joined(separator: "\n\n"),
                               timed: body_, file: item.url, copied: $copied)
                }
            }
            .alert("Copied", isPresented: $copied) { Button("OK", role: .cancel) {} }
            .onAppear {
                let text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
                body_ = TranscriptDocument.parseFrontmatter(text)?.body ?? text
            }
    }
}
