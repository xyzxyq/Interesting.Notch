// Network provider flow adapted from ddddxxx/LyricsKit v0.11.0 (NetEase.swift).
// https://github.com/ddddxxx/LyricsKit/blob/v0.11.0/Sources/LyricsService/Provider/NetEase.swift
// This Source Code Form is subject to the Mozilla Public License, v. 2.0.
// A copy is included in LICENSES/MPL-2.0.txt; https://mozilla.org/MPL/2.0/.
// Adaptations: native Swift concurrency, HTTPS, bounded responses, disk cache,
// shared version matching, independent failure handling and manual search.
import Foundation
import CryptoKit

struct LyricsStore: Sendable {
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InterestingNotch/Lyrics", isDirectory: true)
    private struct Entry: Codable {
        let version: Int
        let track: LyricTrack
        let candidate: LyricCandidate
        let manual: Bool
    }
    private func file(_ track: LyricTrack) -> URL {
        let parts = [track.bundleID, track.title, track.artist, track.album].map(CompactLyrics.normalized)
            + [String(track.duration.rounded())]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    func load(_ track: LyricTrack, requireSynced: Bool) -> LyricCandidate? {
        guard track.isReady,
              let data = try? Data(contentsOf: file(track)), data.count <= 2_000_000,
              let entry = try? JSONDecoder().decode(Entry.self, from: data), (1...2).contains(entry.version),
              entry.track.bundleID == track.bundleID, entry.track.title == track.title,
              entry.track.artist == track.artist, entry.track.album == track.album,
              abs(entry.track.duration - track.duration) < 1,
              LyricsRepository.usable(entry.candidate, track: track, requireSynced: requireSynced),
              entry.manual || (entry.version == 2 && CompactLyrics.match([entry.candidate], track: track, requireSynced: requireSynced) != nil) else { return nil }
        return entry.candidate
    }
    func save(_ candidate: LyricCandidate, for track: LyricTrack, manual: Bool) throws {
        guard track.isReady else { throw CompactLyrics.FetchError.invalidResponse }
        let data = try JSONEncoder().encode(Entry(version: 2, track: track, candidate: candidate, manual: manual))
        guard data.count <= 2_000_000 else { throw CompactLyrics.FetchError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(track), options: .atomic)
    }
    func remove(_ track: LyricTrack) throws {
        let url = file(track)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

enum LyricsRepository {
    private enum SelectionDeadline: Error { case reached }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let live: Transport = { try await URLSession.shared.data(for: $0) }
    struct Resolution {
        let candidate: LyricCandidate
        let cached: Bool
        var cacheError: Bool = false
    }
    struct SearchResult {
        var candidates: [LyricCandidate] = []
        var failures: [String] = []
    }
    static func usable(_ candidate: LyricCandidate, track: LyricTrack, requireSynced: Bool = true) -> Bool {
        !CompactLyrics.timeline(CompactLyrics.parseLRC(candidate.syncedLyrics ?? ""), duration: track.duration).isEmpty
            || (!requireSynced && !CompactLyrics.normalized(candidate.plainLyrics ?? "").isEmpty)
    }
    static func fetch(_ track: LyricTrack, requireSynced: Bool = true, store: LyricsStore = .init(),
                      useCache: Bool = true, transport: @escaping Transport = live) async throws -> Resolution? {
        try Task.checkCancellation()
        guard track.isReady else { return nil }
        if useCache, let cached = store.load(track, requireSynced: requireSynced) {
            return Resolution(candidate: cached, cached: true)
        }
        // Collect independently validated results before choosing; network speed is not quality.
        return try await withThrowingTaskGroup(of: Result<LyricCandidate?, Error>.self) { group in
            group.addTask {
                do {
                    var candidate = try await CompactLyrics.fetch(track, requireSynced: requireSynced, transport: transport)
                    candidate?.source = "LRCLIB"
                    return .success(candidate)
                } catch { return .failure(error) }
            }
            group.addTask {
                do {
                    let candidates = try await netEase(track, transport: transport)
                    return .success(CompactLyrics.match(candidates, track: track, requireSynced: requireSynced))
                } catch { return .failure(error) }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(12)) }
                catch { return .failure(error) }
                return .failure(SelectionDeadline.reached)
            }
            defer { group.cancelAll() }
            var failure: Error?
            var candidates: [LyricCandidate] = []
            var completed = 0
            selection: for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let candidate?):
                    candidates.append(candidate)
                case .failure(let error):
                    if error is SelectionDeadline {
                        failure = failure ?? URLError(.timedOut)
                        break selection
                    }
                    failure = error
                case .success(nil): break
                }
                completed += 1
                if completed == 2 { break }
            }
            group.cancelAll()
            if let candidate = preferred(candidates, track: track) {
                var resolution = Resolution(candidate: candidate, cached: false)
                resolution.cacheError = try await MainActor.run {
                    try Task.checkCancellation()
                    do { try store.save(candidate, for: track, manual: false); return false }
                    catch { return true }
                }
                return resolution
            }
            if let failure { throw failure }
            return nil
        }
    }
    static func preferred(_ candidates: [LyricCandidate], track: LyricTrack) -> LyricCandidate? {
        candidates.sorted {
            let album = CompactLyrics.searchKey(track.album)
            let a = !album.isEmpty && CompactLyrics.searchKey($0.albumName ?? "") == album
            let b = !album.isEmpty && CompactLyrics.searchKey($1.albumName ?? "") == album
            if a != b { return a }
            // Stable provider preference after track/version validation, independent of arrival order.
            if $0.source != $1.source { return ($0.source == "网易云" ? 0 : 1) < ($1.source == "网易云" ? 0 : 1) }
            return abs($0.duration - track.duration) < abs($1.duration - track.duration)
        }.first
    }

    static func search(_ track: LyricTrack, transport: @escaping Transport = live) async -> SearchResult {
        guard track.isReady else { return SearchResult() }
        return await withTaskGroup(of: SearchResult.self) { group in
            group.addTask {
                do {
                    var url = URLComponents(string: "https://lrclib.net/api/search")!
                    url.queryItems = [.init(name: "track_name", value: track.title)]
                    var rows = try JSONDecoder().decode([LyricCandidate].self, from: await data(url.url!, transport: transport))
                    rows = rows.filter { usable($0, track: track) }
                    for i in rows.indices { rows[i].source = "LRCLIB" }
                    return SearchResult(candidates: rows)
                } catch { return SearchResult(failures: ["LRCLIB"]) }
            }
            group.addTask {
                do { return SearchResult(candidates: try await netEase(track, transport: transport).filter { usable($0, track: track) }) }
                catch { return SearchResult(failures: ["网易云"]) }
            }
            var result = SearchResult()
            for await part in group {
                result.candidates += part.candidates
                result.failures += part.failures
            }
            result.candidates.sort {
                let a = CompactLyrics.match([$0], track: track) != nil
                let b = CompactLyrics.match([$1], track: track) != nil
                if a != b { return a }
                let da = abs($0.duration - track.duration), db = abs($1.duration - track.duration)
                if da != db { return da < db }
                return ($0.source ?? "") < ($1.source ?? "")
            }
            result.candidates = Array(result.candidates.prefix(30))
            return result
        }
    }
    private static func data(_ url: URL, transport: Transport) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("interesting-botch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CompactLyrics.FetchError.invalidResponse }
        guard http.statusCode == 200 else { throw CompactLyrics.FetchError.http(http.statusCode) }
        guard data.count <= 2_000_000 else { throw CompactLyrics.FetchError.invalidResponse }
        return data
    }
    // Small provider-specific decoding only; all acceptance decisions use CompactLyrics.match.
    private struct Search: Decodable {
        let code: Int
        let result: Songs?
        struct Songs: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String
            let duration: Double
            let artists: [Artist]
            let album: Album
        }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String }
    }
    private struct Body: Decodable {
        let code: Int
        let lrc: Text?
        struct Text: Decodable { let lyric: String? }
    }
    static func netEase(_ track: LyricTrack, transport: @escaping Transport = live) async throws -> [LyricCandidate] {
        var url = URLComponents(string: "https://music.163.com/api/search/get")!
        url.queryItems = [.init(name: "s", value: track.title + " " + track.artist), .init(name: "type", value: "1"), .init(name: "limit", value: "8")]
        let search = try JSONDecoder().decode(Search.self, from: await data(url.url!, transport: transport))
        guard search.code == 200 else { throw CompactLyrics.FetchError.http(search.code) }
        let songs = Array((search.result?.songs ?? []).prefix(8))
        return try await withThrowingTaskGroup(of: Result<LyricCandidate, Error>.self) { group in
            for song in songs {
                group.addTask {
                    do {
                    var url = URLComponents(string: "https://music.163.com/api/song/lyric")!
                    url.queryItems = [.init(name: "id", value: String(song.id)), .init(name: "lv", value: "1"), .init(name: "kv", value: "1"), .init(name: "tv", value: "-1")]
                    let body = try JSONDecoder().decode(Body.self, from: await data(url.url!, transport: transport))
                    guard body.code == 200 else { throw CompactLyrics.FetchError.http(body.code) }
                    return .success(LyricCandidate(trackName: song.name, artistName: song.artists.map(\.name).joined(separator: " & "),
                                          albumName: song.album.name, duration: song.duration / 1000,
                                          plainLyrics: nil, syncedLyrics: body.lrc?.lyric, source: "网易云"))
                    } catch { return .failure(error) }
                }
            }
            var rows: [LyricCandidate] = []
            var failure: Error?
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let candidate): rows.append(candidate)
                case .failure(let error): failure = error
                }
            }
            if rows.isEmpty, let failure { throw failure }
            return rows
        }
    }
}
