#!/usr/bin/env python3
"""Run MusicManager idle scheduling and empty-source publication checks without launching the app."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/managers/MusicManager.swift').read_text()
method = source.split('    private func updateIdleState(state: Bool) {', 1)[1].split('    private var workItem:', 1)[0]
method = '    func updateIdleState(state: Bool) {' + method
empty = source.split('    private func updateFromPlaybackState(_ state: PlaybackState) {', 1)[1].split('        if isMusicSource != state.isMusicSource', 1)[0]
position = source.split('    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {', 1)[1].split('    func calculateAverageColor()', 1)[0]
empty_check = '''
struct EmptySourceState { let bundleIdentifier = "" }
@MainActor final class EmptySourceCheck: ObservableObject {
    @Published var isPlaying = false
    @Published var isMusicSource = false
    @Published var isPlayerIdle = true
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate = Date()
    @Published var playbackRate: Double = 1
    @Published var isFetchingLyrics = false
    @Published var lyricsStatus = "Lyrics idle"
    var songDuration: TimeInterval = 100
    var debounceIdleTask: Task<Void, Never>?
    var lyricsTask: Task<Void, Never>?
    var lyricsGeneration: UInt64 = 0
    var lyricsTrack: String?
    func updateFromPlaybackState(_ state: EmptySourceState) {
''' + empty + '''    }
    func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
''' + position + '''
}
'''
harness = '''import Foundation
import Combine
struct Defaults {
    enum Key { case waitInterval }
    static subscript(_ key: Key) -> Double { 0.12 }
}
func withAnimation(_ action: () -> Void) { action() }
@MainActor final class IdleCheck {
    var isPlaying = true
    var isPlayerIdle = false
    var debounceIdleTask: Task<Void, Never>?
''' + method + '''
}
''' + empty_check + '''
@main struct Check {
    @MainActor static func main() async throws {
        let model = IdleCheck()
        model.isPlaying = false
        model.updateIdleState(state: false)
        try await Task.sleep(for: .milliseconds(20))
        model.isPlaying = true
        model.updateIdleState(state: true)
        // Pause again before the cancelled task has resumed. That old task must
        // not end this new pause's grace period early.
        model.isPlaying = false
        model.updateIdleState(state: false)
        try await Task.sleep(for: .milliseconds(30))
        assert(!model.isPlayerIdle, "Cancelled pause prematurely removed music")
        try await Task.sleep(for: .milliseconds(160))
        assert(model.isPlayerIdle, "Completed pause must enter idle")
        model.isPlaying = true
        model.updateIdleState(state: true)
        assert(!model.isPlayerIdle, "Resume must immediately present music")
        let source = EmptySourceCheck()
        source.isPlaying = true; source.isMusicSource = true; source.isPlayerIdle = false
        source.elapsedTime = 10; source.timestampDate = Date(timeIntervalSinceNow: -2); source.playbackRate = 1.5
        source.isFetchingLyrics = true; source.lyricsStatus = "Loading lyrics…"; source.lyricsTrack = "old track"
        let lyrics = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        let idle = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        source.lyricsTask = lyrics; source.debounceIdleTask = idle
        let generation = source.lyricsGeneration
        let playingDate = source.timestampDate
        var publications = 0
        let observer = source.objectWillChange.sink { publications += 1 }
        source.updateFromPlaybackState(EmptySourceState())
        assert(publications > 0 && !source.isPlaying && !source.isMusicSource && source.isPlayerIdle)
        let expectedPosition = 10 + source.timestampDate.timeIntervalSince(playingDate) * 1.5
        assert(source.playbackRate == 0 && abs(source.elapsedTime - expectedPosition) < 0.000001,
               "Source loss must freeze the current estimated position")
        assert(!source.isFetchingLyrics && source.lyricsStatus == "Lyrics idle" && source.lyricsTrack == nil)
        assert(source.lyricsGeneration > generation && lyrics.isCancelled && idle.isCancelled,
               "Source loss must invalidate old lyric publications and cancel pending work")
        assert(source.lyricsTask == nil && source.debounceIdleTask == nil, "Idle source must release cancelled task handles")
        let frozenDate = source.timestampDate, frozenPosition = source.elapsedTime
        publications = 0
        for _ in 0..<100 { source.updateFromPlaybackState(EmptySourceState()) }
        assert(publications == 0, "Repeated empty-source updates must not invalidate observers")
        assert(source.timestampDate == frozenDate && source.elapsedTime == frozenPosition,
               "Repeated empty-source updates must not advance a frozen clock")
        source.elapsedTime = 200; publications = 0
        source.updateFromPlaybackState(EmptySourceState())
        assert(source.elapsedTime == source.songDuration && publications == 1,
               "Deduplication must retain idle position clamping when the value actually changes")
        withExtendedLifetime(observer) {}
        print("Music idle checks passed: pause/resume grace period, source-loss freeze/cancellation, no duplicate idle publications")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-idle-check-') as temp:
    swift = Path(temp) / 'Check.swift'
    binary = Path(temp) / 'check'
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-parse-as-library', str(swift), '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary)], check=True)
