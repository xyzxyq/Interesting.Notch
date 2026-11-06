import Foundation

enum ImmersiveFocus {
    static func transitionDuration(enabled: Bool, reducedMotion: Bool) -> Double {
        reducedMotion ? 0.12 : enabled ? 0.42 : 0.28
    }

    // Wake the container at lyric boundaries; only the visible glyphs need a frame clock.
    static func lyricUpdateDates(segments: [LyricSegment], position: Double, sampleDate: Date,
                                 rate: Double, duration: Double, offset: Double, now: Date = Date()) -> [Date] {
        guard position.isFinite, sampleDate.timeIntervalSince1970.isFinite,
              rate.isFinite, rate > 0, offset.isFinite else { return [now] }
        var times = segments.flatMap { [$0.start - offset, $0.start + 0.18 - offset, $0.end - offset, $0.end + 0.4 - offset] }
        if duration.isFinite && duration > 0 { times.append(duration) }
        let dates = times.filter { $0.isFinite && (duration <= 0 || $0 <= duration) }.map {
            sampleDate.addingTimeInterval(($0 - position) / rate)
        }.filter { $0.timeIntervalSince1970.isFinite && $0 > now }
        return [now] + Set(dates).sorted()
    }

    static func presentsIdle(enabled: Bool, music: Bool, playing: Bool) -> Bool {
        enabled && !(music && playing)
    }

    static func sessionStart(enabled: Bool, stored: Date?, now: Date = Date()) -> Date? {
        enabled ? (stored ?? now) : nil
    }

    static func elapsedLabel(since start: Date, now: Date = Date()) -> (value: String, unit: String) {
        let elapsed = now.timeIntervalSince(start)
        let seconds = elapsed.isFinite ? max(0, elapsed) : 0
        let locale = Locale(identifier: "en_US_POSIX")
        return seconds < 3600
            ? (String(format: "%.0f", locale: locale, floor(seconds / 60)), "MIN")
            : (String(format: "%.1f", locale: locale, seconds / 3600), "h")
    }

    // Focus ownership follows the setting, even when AC-only projection is unavailable.
    static func presentsMedia(enabled: Bool, music: Bool, playing: Bool, idle: Bool) -> Bool {
        enabled ? music && playing : playing || !idle
    }

    static func waveProgress(at position: Double, start: Double, end: Double) -> Double {
        guard position.isFinite, start.isFinite, end.isFinite,
              end > start, (end - start).isFinite else { return -1 }
        return min(1, max(0, (position - start) / (end - start)))
    }

    // A slow lens moves at most two points per frame; fast transitions retain 30 Hz.
    static func lyricFrameInterval(width: Double, duration: Double, rate: Double, transitioning: Bool) -> Double {
        guard !transitioning, width.isFinite, duration.isFinite, duration > 0,
              rate.isFinite, rate > 0 else { return 1.0 / 30 }
        return min(1.0 / 15, max(1.0 / 30, 2 * duration / ((max(0, width) + 80) * rate)))
    }

    // Matches CompactLyrics.neighbors' outgoing window; starts exactly at the cue end.
    static func dissolveProgress(at position: Double, end: Double) -> Double {
        guard position.isFinite, end.isFinite else { return 1 }
        return min(1, max(0, (position - end) / 0.4))
    }

    static func eligible(enabled: Bool, music: Bool, playing: Bool, externalPower: Bool,
                         suspended: Bool, savingEnergy: Bool) -> Bool {
        enabled && music && playing && externalPower && !suspended && !savingEnergy
    }
}
