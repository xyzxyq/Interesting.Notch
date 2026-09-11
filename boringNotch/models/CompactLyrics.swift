import Foundation
import NaturalLanguage

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

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).flatMap { chunk in
            splitChunk(String(chunk))
        }
    }

    private static func splitChunk(_ text: String) -> [String] {
        // These short function-word groups are reading units, not a general grammar.
        for phrase in ["也曾像", "和我"] {
            if let range = text.range(of: phrase) {
                return splitChunk(String(text[..<range.lowerBound])) + [phrase]
                    + splitChunk(String(text[range.upperBound...]))
            }
        }
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // NaturalLanguage can omit emoji. Never drop uncovered Characters.
            if cursor < range.lowerBound { words.append(String(text[cursor..<range.lowerBound])) }
            words.append(String(text[range]))
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { words.append(String(text[cursor...])) }
        var result: [String] = []
        var singles = ""
        func flush() {
            if !singles.isEmpty { result.append(singles); singles = "" }
        }
        for word in words {
            if word.count == 1 {
                singles += word
                if singles.count == 3 { flush() }
            } else {
                flush()
                var remainder = word[...]
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(3, remainder.count))
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
            }
        }
        flush()
        return result
    }

    static func timeline(_ lines: [LyricLine], duration: Double) -> [LyricSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        var segments: [LyricSegment] = []
        for (index, line) in lines.enumerated() {
            let upper = min(duration, index + 1 < lines.count ? lines[index + 1].time : duration)
            guard line.time.isFinite, line.time >= 0, upper > line.time else { continue }
            let parts = split(line.text)
            let count = parts.reduce(0) { $0 + $1.count }
            guard count > 0 else { continue }
            // ponytail: character timing cuts long held notes short; replace with word timestamps when available.
            let activeDuration = min(upper - line.time, max(2, Double(count) * 0.4))
            var preceding = 0
            for part in parts {
                let start = line.time + activeDuration * Double(preceding) / Double(count)
                preceding += part.count
                let end = line.time + activeDuration * Double(preceding) / Double(count)
                segments.append(LyricSegment(id: segments.count, start: start, end: end, text: part))
            }
        }
        return segments
    }

    static func segment(at position: Double, in segments: [LyricSegment]) -> LyricSegment? {
        guard position.isFinite else { return nil }
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= position { low = mid + 1 } else { high = mid }
        }
        guard low > 0, position < segments[low - 1].end else { return nil }
        return segments[low - 1]
    }

    static func nextBoundary(after position: Double, in segments: [LyricSegment]) -> Double? {
        guard position.isFinite else { return nil }
        if let current = segment(at: position, in: segments) { return current.end }
        return segments.first(where: { $0.start > position })?.start
    }

    static func transitionDuration(for segment: LyricSegment) -> Double {
        min(0.280, max(0, segment.end - segment.start) * 0.35)
    }
}
