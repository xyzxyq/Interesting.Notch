import Foundation
import IOKit.ps

@main @MainActor struct ImmersiveFocusChecks {
    static func main() {
        for focus in [false, true] {
            for music in [false, true] {
                for playing in [false, true] {
                    for idle in [false, true] {
                        let shown = ImmersiveFocus.presentsMedia(enabled: focus, music: music, playing: playing, idle: idle)
                        if focus {
                            assert(shown == (music && playing), "Focus must reject non-music and paused grace periods")
                        } else {
                            assert(shown == (playing || !idle), "Disabling focus must restore ordinary media behavior")
                        }
                    }
                }
            }
        }
        for mask in 0..<64 {
            let flags = (0..<6).map { mask & (1 << $0) != 0 }
            let active = ImmersiveFocus.eligible(enabled: flags[0], music: flags[1], playing: flags[2],
                externalPower: flags[3], suspended: flags[4], savingEnergy: flags[5])
            assert(active == (mask == 15), "Unsafe activation for state \(mask)")
        }
        let cue = LyricSegment(id: 0, start: 1, end: 3, text: "测试")
        let next = LyricSegment(id: 1, start: 3, end: 5, text: "下一句")
        assert(CompactLyrics.neighbors(at: 2.999, cues: [cue, next]).outgoing == nil)
        assert(CompactLyrics.neighbors(at: 3, cues: [cue, next]).outgoing == cue)
        assert(CompactLyrics.neighbors(at: 3.4, cues: [cue, next]).outgoing == nil)
        assert(CompactLyrics.neighbors(at: 3.1, cues: [cue]).outgoing == cue, "Dissolve during instrumental gap")
        assert(CompactLyrics.neighbors(at: 2, cues: [cue, next]).current == cue, "Backward seek restores current lyric")
        assert(ImmersiveFocus.dissolveProgress(at: 3, end: 3) == 0)
        assert(abs(ImmersiveFocus.dissolveProgress(at: 3.2, end: 3) - 0.5) < 0.0001)
        assert(ImmersiveFocus.dissolveProgress(at: 3.5, end: 3) == 1)
        assert(ImmersiveFocus.dissolveProgress(at: .nan, end: 3) == 1)
        assert(ImmersiveFocus.waveProgress(at: 0, start: 1, end: 3) == 0)
        assert(ImmersiveFocus.waveProgress(at: 1, start: 1, end: 3) == 0)
        assert(ImmersiveFocus.waveProgress(at: 2, start: 1, end: 3) == 0.5)
        assert(ImmersiveFocus.waveProgress(at: 2, start: 1, end: 9) == 0.125,
               "A longer cue must move its wave more slowly")
        assert(ImmersiveFocus.waveProgress(at: 3, start: 1, end: 3) == 1)
        assert(ImmersiveFocus.waveProgress(at: 4, start: 1, end: 3) == 1)
        assert(ImmersiveFocus.waveProgress(at: 3, start: 3, end: 5) == 0, "Next cue restarts its wave")
        assert(ImmersiveFocus.waveProgress(at: 1.5, start: 1, end: 3) == 0.25, "Seek restores wave position")
        assert(ImmersiveFocus.waveProgress(at: .nan, start: 1, end: 3) == -1)
        assert(ImmersiveFocus.waveProgress(at: 1, start: 1, end: 1) == -1)
        assert(ImmersiveFocus.waveProgress(at: 1, start: 2, end: 1) == -1)
        assert(ImmersiveFocus.waveProgress(at: 1, start: 1, end: .infinity) == -1)
        let info = BatteryActivityManager.shared.initializeBatteryInfo()
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            assert(info.isPluggedIn == (source == kIOPSACPowerValue), "Power gate disagrees with IOKit")
            print("Live power source: \(source), plugged in: \(info.isPluggedIn)")
        }
        print("Immersive focus: 64 activation combinations passed")
    }
}
