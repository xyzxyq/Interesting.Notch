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
}

extension PlaybackState {
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
        if let date { return (currentTime, date) }
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
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
    }
}
