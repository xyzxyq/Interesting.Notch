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

struct LyricTrack: Codable, Equatable, Sendable {
    let bundleID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var isReady: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && duration.isFinite && duration > 0
    }
}

struct LyricCandidate: Codable, Equatable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let plainLyrics: String?
    let syncedLyrics: String?
    var source: String? = nil
}

enum CompactLyrics {
    enum TimeOfDay: CaseIterable { case dawn, day, dusk, night }

    static func timeOfDay(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> TimeOfDay {
        switch calendar.component(.hour, from: date) {
        case 0..<8: return .dawn
        case 8..<17: return .day
        case 17..<19: return .dusk
        default: return .night
        }
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func match(_ candidates: [LyricCandidate], track: LyricTrack, requireSynced: Bool = true) -> LyricCandidate? {
        guard !normalized(track.title).isEmpty, !normalized(track.artist).isEmpty,
              track.duration.isFinite, track.duration > 0 else { return nil }
        let matches = candidates.filter {
            hasExpectedScript($0, track: track)
                && (titleKey($0.trackName) == titleKey(track.title) || lyricSubtitleMatches($0, track: track))
                && $0.duration.isFinite && abs($0.duration - track.duration) <= 2
                && ((!requireSynced && !normalized($0.plainLyrics ?? "").isEmpty)
                    || !timeline(parseLRC($0.syncedLyrics ?? ""), duration: track.duration).isEmpty)
        }
        let exactArtists = matches.filter { searchKey($0.artistName) == searchKey(track.artist) }
        let artistMatches = exactArtists.isEmpty ? matches.filter {
            !searchKey(track.album).isEmpty && searchKey($0.albumName ?? "") == searchKey(track.album)
                && romanizedArtistMatches($0.artistName, track.artist)
        } : exactArtists
        let albumMatches = artistMatches.filter { !track.album.isEmpty && searchKey($0.albumName ?? "") == searchKey(track.album) }
        let pool = albumMatches.isEmpty ? artistMatches : albumMatches
        // Duplicate database records with the same lyric timeline are not ambiguous.
        guard let first = pool.first else { return nil }
        return pool.allSatisfy { parseLRC($0.syncedLyrics ?? "") == parseLRC(first.syncedLyrics ?? "")
            && (requireSynced || $0.plainLyrics == first.plainLyrics) } ? first : nil
    }

    /// Conservative automatic selection, not language detection: Chinese title
    /// and artist metadata require Han lyric text. Other versions stay selectable manually.
    static func hasExpectedScript(_ candidate: LyricCandidate, track: LyricTrack) -> Bool {
        func containsHan(_ text: String) -> Bool {
            text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        }
        guard containsHan(track.title), containsHan(track.artist) else { return true }
        // Japanese/Korean metadata does not establish a Chinese-script expectation.
        guard (track.title + track.artist).range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#,
                                               options: .regularExpression) == nil else { return true }
        let synced = parseLRC(candidate.syncedLyrics ?? "").map(\.text)
        let lines = (synced.isEmpty ? (candidate.plainLyrics ?? "").components(separatedBy: .newlines) : synced)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.range(of: #"^(?:作词|作曲|编曲|制作人|词|曲|演唱|歌手|专辑|歌名|录音|混音|母带|监制|出品|发行|版权|翻译|译词|歌词|Lyricist|Composer|Arranger)\s*[:：]"#,
                                             options: [.regularExpression, .caseInsensitive]) == nil }
        guard !lines.isEmpty else { return false }
        let hanLines = lines.filter { line in
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let han = letters.filter { $0.properties.isIdeographic }.count
            return han >= 2 && Double(han) / Double(max(1, letters.count)) >= 0.2
        }.count
        // A credit or a single Chinese label must not validate a full romanization.
        return hanLines >= min(2, lines.count) && Double(hanLines) / Double(lines.count) >= 0.2
    }

    private static func lyricSubtitle(_ title: String) -> (base: String, quote: String)? {
        let parts = title.split(whereSeparator: { "(（)）".contains($0) }).map(String.init)
        guard parts.count == 2, let last = title.last, "）)".contains(last),
              parts[1].range(of: #"^\p{Han}{4,20}$"#, options: .regularExpression) != nil else { return nil }
        return (parts[0], parts[1])
    }

    private static func lyricSubtitleMatches(_ candidate: LyricCandidate, track: LyricTrack) -> Bool {
        guard let subtitle = lyricSubtitle(track.title),
              titleKey(subtitle.base) == titleKey(candidate.trackName),
              searchKey(candidate.artistName) == searchKey(track.artist) else { return false }
        func releaseKey(_ album: String) -> String {
            titleKey(album.replacingOccurrences(of: #"\s+-\s+(?:Single|EP)$"#, with: "",
                                               options: [.regularExpression, .caseInsensitive]))
        }
        // A quoted lyric is not a version label. Require the same single, artist, duration
        // and the entire quote in a timed line before treating it as an alternate title.
        guard releaseKey(track.album) == titleKey(track.title),
              releaseKey(candidate.albumName ?? "") == titleKey(subtitle.base) else { return false }
        return parseLRC(candidate.syncedLyrics ?? "").contains {
            searchKey($0.text).contains(searchKey(subtitle.quote))
        }
    }

    private static func romanizedArtistMatches(_ first: String, _ second: String) -> Bool {
        func chineseName(_ name: String) -> Bool {
            name.range(of: #"^\p{Han}{2,4}$"#, options: .regularExpression) != nil
        }
        let a = searchKey(first), b = searchKey(second)
        guard chineseName(a) != chineseName(b) else { return false }
        let chinese = chineseName(a) ? a : b
        let latin = chineseName(a) ? b : a
        guard !latin.isEmpty, latin.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { return false }
        let syllables = chinese.applyingTransform(.toLatin, reverse: false)?
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(separator: " ").map(String.init) ?? []
        guard syllables.count == chinese.count else { return false }
        // ponytail: only direct pinyin and surname-first/last forms; stage names require verified aliases.
        let surnames = chinese.count == 4 ? [1, 2] : [1]
        return syllables.joined() == latin || surnames.contains {
            (Array(syllables.dropFirst($0)) + Array(syllables.prefix($0))).joined() == latin
        }
    }

    static func titleKey(_ value: String) -> String {
        // Strip only explicit soundtrack-use labels; live/remix/version markers remain significant.
        let title = displayText(value, languages: ["zh-Hans"])
        let base = title.replacingOccurrences(of: #"\s*[-—–－]\s*《[^》]+》\s*(?:电视剧|电影|影视剧|网剧|动画片|动画)?\s*(?:插曲|主题曲|片头曲|片尾曲)\s*$"#,
                                             with: "", options: .regularExpression)
        return searchKey(base)
    }

    static func searchKey(_ value: String) -> String {
        displayText(value, languages: ["zh-Hans"])
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    enum FetchError: Error { case http(Int), invalidResponse }

    static func retryDelay(for error: Error) -> UInt64? {
        if let urlError = error as? URLError, urlError.code != .cancelled { return 60_000_000_000 }
        if case FetchError.http(let code) = error, code == 429 || code >= 500 { return 60_000_000_000 }
        if case FetchError.invalidResponse = error { return 60_000_000_000 }
        if error is DecodingError { return 60_000_000_000 }
        return nil
    }

    static func fetch(_ track: LyricTrack, requireSynced: Bool = true,
                      transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
                      sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> LyricCandidate? {
        guard track.isReady else { return nil }
        // Search indexes do not normalize Chinese scripts, unlike our result matcher.
        var queries = [track]
        for language in ["zh-Hans", "zh-Hant"] {
            let variant = LyricTrack(bundleID: track.bundleID,
                                     title: displayText(track.title, languages: [language]),
                                     artist: displayText(track.artist, languages: [language]),
                                     album: displayText(track.album, languages: [language]), duration: track.duration)
            if !queries.contains(variant) { queries.append(variant) }
        }
        var failure: Error?
        for query in queries {
        var reachedService = false
        for stage in 0..<4 {
            try Task.checkCancellation()
            // A title-only lookup recovers localized artist names; match still verifies the artist.
            // Do not spend another request on an outage or on a track lacking corroborating album data.
            if stage == 3 && (!reachedService || searchKey(track.album).isEmpty) { break }
            var url = URLComponents(string: "https://lrclib.net/api/" + (stage == 0 ? "get" : "search"))!
            let title = stage == 3 ? (lyricSubtitle(query.title)?.base ?? query.title) : query.title
            url.queryItems = [.init(name: "track_name", value: title)]
            if stage < 3 { url.queryItems?.append(.init(name: "artist_name", value: query.artist)) }
            if stage < 2 && !query.album.isEmpty { url.queryItems?.append(.init(name: "album_name", value: query.album)) }
            if stage == 0 { url.queryItems?.append(.init(name: "duration", value: String(track.duration))) }
            var request = URLRequest(url: url.url!, timeoutInterval: 8)
            request.setValue("InterestingNotch/1.0", forHTTPHeaderField: "User-Agent")
            var requestFailure: Error?
            for attempt in 0..<3 {
                do {
                    try Task.checkCancellation()
                    let (data, response) = try await transport(request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
                    if http.statusCode == 404 {
                        requestFailure = nil
                        reachedService = true
                        break
                    }
                    guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
                    let candidates = stage == 0 ? [try JSONDecoder().decode(LyricCandidate.self, from: data)]
                        : try JSONDecoder().decode([LyricCandidate].self, from: data)
                    requestFailure = nil
                    reachedService = true
                    if let match = match(candidates, track: track, requireSynced: requireSynced) { return match }
                    break
                } catch {
                    try Task.checkCancellation()
                    if (error as? URLError)?.code == .cancelled { throw error }
                    requestFailure = error
                    let retryable: Bool
                    if case FetchError.http(let status) = error { retryable = status == 429 || status >= 500 }
                    else { retryable = error is URLError }
                    guard retryable && attempt < 2 else { break }
                    try await sleep(UInt64(attempt + 1) * 1_000_000_000)
                }
            }
            if let requestFailure { failure = requestFailure }
        }
        // Changing spelling cannot fix an unavailable service; keep outage retries bounded.
        if !reachedService, let failure { throw failure }
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
