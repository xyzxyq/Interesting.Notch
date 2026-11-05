import Foundation

enum ImmersiveFocus {
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

enum ImmersiveLyricStyle: String, CaseIterable {
    case glow, particles, ripple

    var title: String {
        switch self {
        case .glow: "微光"
        case .particles: "粒子"
        case .ripple: "水波"
        }
    }
}
