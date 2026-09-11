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
            normalized($0.trackName) == normalized(track.title)
                && normalized($0.artistName) == normalized(track.artist)
                && (normalized(track.album).isEmpty || normalized($0.albumName ?? "") == normalized(track.album))
                && $0.duration.isFinite && abs($0.duration - track.duration) <= 2
                && (!requireSynced || !parseLRC($0.syncedLyrics ?? "").filter { !$0.text.isEmpty }.isEmpty)
        }
        return matches.count == 1 ? matches[0] : nil
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
            // ponytail: LRC lacks vocal end times; long gaps use character timing.
            // Replace this estimate with word/vocal timestamps when available.
            let estimated = max(2, Double(count) * 0.4)
            let reachesEnd = upper == duration && duration - line.time <= max(5, estimated + 1)
            let end = next?.text.isEmpty == true || reachesEnd
                ? upper : min(upper, line.time + estimated)
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
