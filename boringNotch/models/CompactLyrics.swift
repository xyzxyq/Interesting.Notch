import Foundation

struct LyricLine: Equatable {
    let time: Double
    let text: String
}

struct LyricSegment: Equatable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

struct LyricTrack: Equatable {
    let bundleID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

struct LyricCandidate: Decodable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum CompactLyrics {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func match(_ candidates: [LyricCandidate], track: LyricTrack, requireSynced: Bool = true) -> LyricCandidate? {
        guard !normalized(track.title).isEmpty, !normalized(track.artist).isEmpty,
              track.duration.isFinite, track.duration > 0 else { return nil }
        let matches = candidates.filter {
            searchKey($0.trackName) == searchKey(track.title)
                && searchKey($0.artistName) == searchKey(track.artist)
                && $0.duration.isFinite && abs($0.duration - track.duration) <= 2
                && (!requireSynced || !parseLRC($0.syncedLyrics ?? "").filter { !$0.text.isEmpty }.isEmpty)
        }
        let albumMatches = matches.filter { !track.album.isEmpty && searchKey($0.albumName ?? "") == searchKey(track.album) }
        let pool = albumMatches.isEmpty ? matches : albumMatches
        // Duplicate database records with the same lyric timeline are not ambiguous.
        guard let first = pool.first else { return nil }
        return pool.allSatisfy { parseLRC($0.syncedLyrics ?? "") == parseLRC(first.syncedLyrics ?? "")
            && (requireSynced || $0.plainLyrics == first.plainLyrics) } ? first : nil
    }

    static func searchKey(_ value: String) -> String {
        displayText(value, languages: ["zh-Hans"])
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    enum FetchError: Error { case http(Int), invalidResponse }

    static func fetch(_ track: LyricTrack, requireSynced: Bool = true,
                      transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
                      sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> LyricCandidate? {
        guard !normalized(track.artist).isEmpty, !normalized(track.title).isEmpty,
              track.duration.isFinite, track.duration > 0 else { return nil }
        var failure: Error?
        for stage in 0..<3 {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://lrclib.net/api/" + (stage == 0 ? "get" : "search"))!
            url.queryItems = [.init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist)]
            if stage < 2 && !track.album.isEmpty { url.queryItems?.append(.init(name: "album_name", value: track.album)) }
            if stage == 0 { url.queryItems?.append(.init(name: "duration", value: String(track.duration))) }
            var request = URLRequest(url: url.url!, timeoutInterval: 8)
            request.setValue("InterestingNotch/1.0", forHTTPHeaderField: "User-Agent")
            for attempt in 0..<3 {
                do {
                    try Task.checkCancellation()
                    let (data, response) = try await transport(request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
                    if http.statusCode == 404 { break }
                    guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
                    let candidates = stage == 0 ? [try JSONDecoder().decode(LyricCandidate.self, from: data)]
                        : try JSONDecoder().decode([LyricCandidate].self, from: data)
                    if let match = match(candidates, track: track, requireSynced: requireSynced) { return match }
                    break
                } catch {
                    try Task.checkCancellation()
                    failure = error
                    let retryable: Bool
                    if case FetchError.http(let status) = error { retryable = status == 429 || status >= 500 }
                    else { retryable = error is URLError }
                    guard retryable && attempt < 2 else { break }
                    try await sleep(UInt64(attempt + 1) * 1_000_000_000)
                }
            }
        }
        if let failure { throw failure }
        return nil
    }

    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#)
    private static let offsetTag = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)

    static func parseLRC(_ source: String) -> [LyricLine] {
        let nsSource = source as NSString
        let offsetMatch = offsetTag.firstMatch(in: source, range: NSRange(location: 0, length: nsSource.length))
        let offset = offsetMatch.flatMap { Double(nsSource.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        guard offset.isFinite else { return [] }
        var lines: [LyricLine] = []
        for raw in source.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = timeTag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                      let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                let fraction = match.range(at: 3)
                let decimal = fraction.location == NSNotFound ? 0 : Double("0." + ns.substring(with: fraction)) ?? 0
                lines.append(LyricLine(time: max(0, minutes * 60 + seconds + decimal + offset), text: text))
            }
        }
        // Preserve source order when bilingual or duplicate timestamps coincide.
        let sorted = lines.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }
        var result: [LyricLine] = []
        for (_, line) in sorted {
            if let last = result.last, last.time == line.time {
                result[result.count - 1] = LyricLine(time: last.time, text: last.text + line.text)
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// Only Chinese script is converted. Other languages are not machine-translated.
    static func displayText(_ text: String, languages: [String] = Locale.preferredLanguages) -> String {
        guard let first = languages.first else { return text }
        let language = Locale(identifier: first).language
        guard language.languageCode?.identifier == "zh" else { return text }
        let transform = language.script?.identifier == "Hant" ? "Simplified-Traditional" : "Traditional-Simplified"
        return text.applyingTransform(StringTransform(transform), reverse: false) ?? text
    }

    static func timeline(_ lines: [LyricLine], duration: Double) -> [LyricSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        var result: [LyricSegment] = []
        for (index, line) in lines.enumerated() {
            guard line.time.isFinite, line.time >= 0, !line.text.isEmpty else { continue }
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            let upper = min(duration, next?.time ?? duration)
            guard upper > line.time else { continue }
            let count = line.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            guard count > 0 else { continue }
            // ponytail: line LRC has no word/vocal end times. Preserve source timing;
            // only explicit blank cues identify instrumental gaps. Do not guess from length.
            let end = upper
            result.append(LyricSegment(id: result.count, start: line.time, end: end, text: line.text))
        }
        return result
    }

    static func phase(at position: Double, cues: [LyricSegment], duration: Double) -> LyricPhase {
        guard position.isFinite, duration.isFinite, duration > 0 else { return .waves }
        guard let last = cues.last else { return .waves }
        if position >= max(0, duration - 0.2) { return .finished }
        // Current vocals always take priority over the album-cover ending.
        if let cue = cues.last(where: { $0.start <= position && position < $0.end }) {
            return .lyrics(cue)
        }
        if position >= max(last.end, duration - 5) { return .outro }
        return .waves
    }

    static func dissolve(at position: Double, duration: Double) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let start = max(0, duration - 1.2)
        let end = max(start + 0.001, duration - 0.2)
        let p = min(1, max(0, (position - start) / (end - start)))
        return p * p * (3 - 2 * p)
    }
}

enum LyricPhase: Equatable {
    case lyrics(LyricSegment)
    case waves
    case outro
    case finished
}
