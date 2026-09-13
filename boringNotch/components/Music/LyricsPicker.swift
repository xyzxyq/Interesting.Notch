import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsPicker: View {
    struct Request: Identifiable {
        let id = UUID()
        let track: LyricTrack
    }
    let track: LyricTrack
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var requestID = 0
    @State private var rows: [LyricCandidate] = []
    @State private var selection: Int?
    @State private var loading = false
    @State private var message = ""
    private var changedTrack: Bool { music.currentLyricTrack != track }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Brand.localized("Select synchronized lyrics")).font(.title2.bold())
            Text("\(Brand.localized("Current song:")) \(track.title) · \(track.artist)").foregroundStyle(.secondary)
            HStack {
                TextField(Brand.localized("Song title"), text: $title)
                TextField(Brand.localized("Artist"), text: $artist)
                Button(Brand.localized("Search")) { requestID += 1 }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.trackName).fontWeight(.medium)
                            Text("\(row.artistName) · \(row.albumName ?? Brand.localized("Unknown album"))").font(.caption)
                            Text("\(row.source == "Imported LRC" ? Brand.localized("Imported LRC") : row.source ?? Brand.localized("Unknown source")) · \(Int(row.duration.isFinite ? max(0, min(86400, row.duration)) : 0)) \(Brand.localized("seconds"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(index)
                    }
                }.frame(minWidth: 280)
                ScrollView {
                    Text(selected.map { CompactLyrics.parseLRC($0.syncedLyrics ?? "").map(\.text).joined(separator: "\n") } ?? Brand.localized("Select a result on the left to preview lyrics"))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(minWidth: 230)
            }.frame(height: 280)
            if loading { ProgressView(Brand.localized("Searching LRCLIB and NetEase Cloud Music…")).controlSize(.small) }
            if changedTrack {
                Text(Brand.localized("The song changed. Close and reopen this sheet; these results will not be applied to the new song.")).foregroundStyle(.orange)
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let selected, CompactLyrics.match([selected], track: track) == nil {
                Text(Brand.localized("This result did not pass automatic version matching. Please listen and confirm before using it.")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(Brand.localized("Import LRC…")) { importFile() }.disabled(changedTrack)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Brand.localized("Use and remember")) { if let selected { apply(selected) } }
                    .disabled(selected == nil || changedTrack).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 650)
        .onAppear { title = track.title; artist = track.artist }
        .task(id: requestID) {
            loading = true; rows = []; selection = nil; message = ""
            let query = LyricTrack(bundleID: track.bundleID, title: title.isEmpty ? track.title : title,
                                   artist: artist.isEmpty ? track.artist : artist, album: track.album, duration: track.duration)
            let result = await LyricsRepository.search(query)
            guard !Task.isCancelled else { return }
            rows = result.candidates
            loading = false
            message = rows.isEmpty ? Brand.localized("No synchronized lyrics were found. Change the query or import a timestamped LRC file.") : Brand.localized("The selected lyrics will be saved locally and used automatically next time.")
            if !result.failures.isEmpty { message += " " + Brand.localized("Temporarily unavailable:") + " " + result.failures.joined(separator: ", ") }
        }
    }
    private var selected: LyricCandidate? {
        guard let selection, rows.indices.contains(selection) else { return nil }
        return rows[selection]
    }
    private func apply(_ candidate: LyricCandidate) {
        do { try music.chooseLyrics(candidate, for: track); dismiss() }
        catch { message = error.localizedDescription }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw CompactLyrics.FetchError.invalidResponse }
                let content = try String(contentsOf: url, encoding: .utf8)
                apply(LyricCandidate(trackName: track.title, artistName: track.artist, albumName: track.album,
                                     duration: track.duration, plainLyrics: nil, syncedLyrics: content, source: "Imported LRC"))
            } catch { message = Brand.localized("Cannot import: use a timestamped UTF-8 LRC file smaller than 2 MB.") }
        }
    }
}
