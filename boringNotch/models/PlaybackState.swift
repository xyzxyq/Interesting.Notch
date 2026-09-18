//
//  PlaybackState.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

struct PlaybackState {
    var bundleIdentifier: String
    var isPlaying: Bool = false
    var title: String = "I'm Handsome"
    var artist: String = "Me"
    var album: String = "Self Love"
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false
    var isAudioFallback: Bool = false
    var catalogID: Int?
}

extension PlaybackState {
    /// Dedicated music clients get lyrics and music effects. Other MediaRemote
    /// sources retain the basic artwork/icon and playback visualizer.
    var isMusicSource: Bool {
        switch bundleIdentifier {
        case "com.apple.Music", "com.tencent.QQMusic", "com.netease.163music",
             "com.spotify.client", "com.github.th-ch.youtube-music":
            return true
        default:
            return false
        }
    }

    /// Keep the position and its reference date together, including transport-only diffs.
    func clockUpdate(elapsed: Double?, timestamp: String?, diff: Bool,
                     playing: Bool?, rate: Double?, now: Date = Date()) -> (position: Double, date: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = timestamp.flatMap { value -> Date? in
            if let parsed = formatter.date(from: value) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        if let elapsed, elapsed.isFinite { return (max(0, elapsed), date ?? now) }
        guard diff else { return (0, date ?? now) }
        if let date {
            guard date >= lastUpdated else { return (currentTime, lastUpdated) }
            let advance = isPlaying ? date.timeIntervalSince(lastUpdated) * max(0, playbackRate) : 0
            return (max(0, currentTime + advance), date)
        }
        if (playing != nil && playing != isPlaying) || (rate != nil && rate != playbackRate) {
            let advance = isPlaying ? max(0, now.timeIntervalSince(lastUpdated)) * max(0, playbackRate) : 0
            return (max(0, currentTime + advance), now)
        }
        return (currentTime, lastUpdated)
    }
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.isPlaying == rhs.isPlaying
            && lhs.catalogID == rhs.catalogID
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isAudioFallback == rhs.isAudioFallback
    }
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let uniqueIdentifier: MediaItemIdentifier?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

extension PlaybackState {
    /// Diffs belong to one player. Never combine a new player's partial metadata
    /// with the preceding player's song, artwork, or playback clock.
    func applying(_ update: NowPlayingUpdate, now: Date = Date()) -> PlaybackState {
        let payload = update.payload
        let source = [payload.parentApplicationBundleIdentifier, payload.bundleIdentifier]
            .compactMap { $0 }.first { !$0.isEmpty }
        let diff = update.diff == true && (source == nil || source == bundleIdentifier)
        var state = diff ? self : PlaybackState(bundleIdentifier: source ?? "")
        state.bundleIdentifier = source ?? (diff ? bundleIdentifier : "")
        // A title change without an ID must not retain the previous catalog identity.
        if let identifier = payload.uniqueIdentifier {
            state.catalogID = identifier.catalogID
        } else {
            state.catalogID = diff && (payload.title == nil || payload.title == title) ? catalogID : nil
        }
        state.title = payload.title ?? (diff ? title : "")
        state.artist = payload.artist ?? (diff ? artist : "")
        state.album = payload.album ?? (diff ? album : "")
        state.duration = payload.duration ?? (diff ? duration : 0)
        let clock = clockUpdate(elapsed: payload.elapsedTime, timestamp: payload.timestamp,
                                diff: diff, playing: payload.playing, rate: payload.playbackRate, now: now)
        state.currentTime = clock.position
        state.lastUpdated = clock.date
        state.isPlaying = payload.playing ?? (diff ? isPlaying : false)
        state.playbackRate = payload.playbackRate ?? (diff ? playbackRate : 1)
        if let shuffle = payload.shuffleMode { state.isShuffled = shuffle != 1 }
        if let repeatMode = payload.repeatMode { state.repeatMode = RepeatMode(rawValue: repeatMode) ?? .off }
        if let artwork = payload.artworkData {
            state.artwork = Data(base64Encoded: artwork.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        state.volume = payload.volume ?? (diff ? volume : 0.5)
        return state
    }
}

extension PlaybackState {
    /// Keep real MediaRemote metadata separate from audio-only video presence.
    func withVideoAudioFallback(activeSources: [String], runningSources: Set<String>,
                               previous: PlaybackState) -> PlaybackState {
        guard !isPlaying else { return self }
        let source = activeSources.contains(previous.bundleIdentifier)
            ? previous.bundleIdentifier : activeSources.sorted().first
        if let source {
            var state = PlaybackState(bundleIdentifier: source)
            state.title = ""
            state.artist = ""
            state.album = ""
            state.isPlaying = true
            state.playbackRate = 0
            state.isAudioFallback = true
            return state
        }
        if previous.isAudioFallback {
            guard runningSources.contains(previous.bundleIdentifier) else {
                return previous.endingPlayback()
            }
            var paused = previous
            paused.isPlaying = false
            return paused
        }
        return self
    }

    func endingPlayback(now: Date = Date()) -> PlaybackState {
        var ended = self
        let clock = clockUpdate(elapsed: nil, timestamp: nil, diff: true, playing: false, rate: 0, now: now)
        ended.currentTime = min(max(0, duration), clock.position)
        ended.lastUpdated = now
        ended.isPlaying = false
        ended.playbackRate = 0
        ended.bundleIdentifier = ""
        ended.isAudioFallback = false
        return ended
    }
}

// MediaRemote identifiers can be numeric catalog IDs or opaque strings.
enum MediaItemIdentifier: Codable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let id = try? value.decode(Int.self) { self = .number(id) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let id): try value.encode(id)
        case .string(let id): try value.encode(id)
        }
    }

    var catalogID: Int? {
        switch self {
        case .number(let id): return id > 0 ? id : nil
        case .string(let id): return Int(id).flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

struct LocalizedMusicMetadata: Decodable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let collectionName: String

    static func lookupURL(id: Int, languages: [String] = Locale.preferredLanguages) -> URL? {
        guard id > 0, let preferred = languages.first else { return nil }
        let language = Locale(identifier: preferred).language
        guard language.languageCode?.identifier == "zh" else { return nil }
        let traditional = language.script?.identifier == "Hant"
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: String(id)),
                          URLQueryItem(name: "country", value: traditional ? "tw" : "cn"),
                          URLQueryItem(name: "lang", value: traditional ? "zh_tw" : "zh_cn")]
        return url.url
    }

    static func decode(_ data: Data, id: Int) throws -> Self? {
        struct Response: Decodable { let results: [LocalizedMusicMetadata] }
        return try JSONDecoder().decode(Response.self, from: data).results.first {
            $0.trackId == id && !$0.trackName.isEmpty && !$0.artistName.isEmpty
        }
    }
}
