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
            Text("选择同步歌词").font(.title2.bold())
            Text("当前歌曲：\(track.title) · \(track.artist)").foregroundStyle(.secondary)
            HStack {
                TextField("歌曲名称", text: $title)
                TextField("歌手", text: $artist)
                Button("搜索") { requestID += 1 }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.trackName).fontWeight(.medium)
                            Text("\(row.artistName) · \(row.albumName ?? "未知专辑")").font(.caption)
                            Text("\(row.source ?? "未知来源") · \(Int(row.duration.isFinite ? max(0, min(86400, row.duration)) : 0)) 秒")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(index)
                    }
                }.frame(minWidth: 280)
                ScrollView {
                    Text(selected.map { CompactLyrics.parseLRC($0.syncedLyrics ?? "").map(\.text).joined(separator: "\n") } ?? "选择左侧结果，预览歌词")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(minWidth: 230)
            }.frame(height: 280)
            if loading { ProgressView("正在搜索 LRCLIB 和网易云…").controlSize(.small) }
            if changedTrack {
                Text("歌曲已切换，请关闭后重新打开。当前结果不会应用到新歌。").foregroundStyle(.orange)
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let selected, CompactLyrics.match([selected], track: track) == nil {
                Text("此结果未通过自动版本校验，请试听并核对后再使用。").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("导入 LRC…") { importFile() }.disabled(changedTrack)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用并记住") { if let selected { apply(selected) } }
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
            message = rows.isEmpty ? "未找到同步歌词。可以修改关键词，或导入带时间戳的 LRC 文件。" : "选择后将保存到本机，下次播放自动使用。"
            if !result.failures.isEmpty { message += " 暂不可用：" + result.failures.joined(separator: "、") }
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
                                     duration: track.duration, plainLyrics: nil, syncedLyrics: content, source: "导入 LRC"))
            } catch { message = "无法导入：需要小于 2 MB、UTF-8 编码的同步 LRC 文件。" }
        }
    }
}
