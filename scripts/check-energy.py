#!/usr/bin/env python3
"""Exercise production lifecycle gates without capturing audio or changing players."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / 'boringNotch/MediaControllers/NowPlayingController.swift').read_text()
poll = '    func updateVideoPolling() {' + controller.split('    private func updateVideoPolling() {', 1)[1].split('    @MainActor\n    private func refreshLocalizedMetadata()', 1)[0]
audio = (root / 'boringNotch/managers/MusicEdgeAudio.swift').read_text()
demand = '    func setDemand(' + audio.split('    func setDemand(', 1)[1].split('    private func configure(', 1)[0]
spectrum = (root / 'boringNotch/components/Music/MusicVisualizer.swift').read_text().split('struct AudioSpectrumView:', 1)[0]
manager = (root / 'boringNotch/managers/MusicManager.swift').read_text()
decode = 'if let source = CGImageSourceCreateWithData' + manager.split('if let source = CGImageSourceCreateWithData', 1)[1].split('                DispatchQueue.main.async', 1)[0]
decode = 'func decodeArtwork(_ artworkData: Data) -> NSImage? {\n' + decode + 'return artworkImage\n}\nreturn nil\n}\n'
source = '''import AppKit
import ImageIO
import Combine
@MainActor final class NotchMotionEnvironment {
    static let shared = NotchMotionEnvironment()
    var suspended = false
}
@MainActor final class PollCheck {
    var videoApplications: [String: pid_t] = [:]
    var remotePlaybackState = PlaybackState(bundleIdentifier: "")
    var videoAudioObserver: AnyCancellable?
    func refreshVideoAudio() {}
''' + poll + '''
}
@MainActor final class DemandCheck {
    var consumers: [UUID: String] = [:]
    var requested: String?
    func configure(bundleID: String?, active: Bool) { requested = active ? bundleID : nil }
''' + demand + '''
}
''' + decode + '''
@main struct Check {
    @MainActor static func main() {
        let poll = PollCheck()
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver == nil, "No video app must mean no polling")
        poll.videoApplications = ["video": 1]
        poll.updateVideoPolling()
        let timer = poll.videoAudioObserver
        assert(timer != nil)
        poll.updateVideoPolling()
        assert(timer === poll.videoAudioObserver, "Refresh must not accumulate timers")
        poll.remotePlaybackState.isPlaying = true
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver == nil, "Native music/video events must disable fallback polling")
        poll.remotePlaybackState.isPlaying = false
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver != nil, "Paused native player must allow fallback again")
        NotchMotionEnvironment.shared.suspended = true
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver == nil, "Screen sleep must stop polling")
        NotchMotionEnvironment.shared.suspended = false
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver != nil)
        poll.videoApplications = [:]
        poll.updateVideoPolling()
        assert(poll.videoAudioObserver == nil, "Last video exit must stop polling")

        let audio = DemandCheck(), first = UUID(), second = UUID()
        audio.setDemand(first, bundleID: "music", active: true)
        audio.setDemand(second, bundleID: "music", active: true)
        audio.setDemand(first, bundleID: nil, active: false)
        assert(audio.requested == "music", "Removing one screen must preserve capture on another")
        audio.setDemand(second, bundleID: "spotify", active: true)
        assert(audio.requested == "spotify")
        audio.setDemand(second, bundleID: nil, active: false)
        assert(audio.requested == nil, "Last window disappearing must stop audio capture")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8000, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let thumbnail = decodeArtwork(bitmap.representation(using: .png, properties: [:])!)!
        assert(thumbnail.representations[0].pixelsWide == 512 && thumbnail.representations[0].pixelsHigh == 256, "Thumbnail size: \(thumbnail.representations[0].pixelsWide)x\(thumbnail.representations[0].pixelsHigh)")
        assert(decodeArtwork(Data([0, 1, 2])) == nil, "Corrupt artwork must be rejected")

        let spectrum = AudioSpectrum(frame: .zero)
        spectrum.setPlaying(true)
        let bars = spectrum.layer!.sublayers!
        assert(bars.count == 4 && bars.allSatisfy { $0.animation(forKey: "scaleY") is CAKeyframeAnimation })
        spectrum.setPlaying(false)
        assert(bars.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        spectrum.setPlaying(true)
        assert(bars.allSatisfy { $0.animation(forKey: "scaleY") != nil })
        spectrum.setPlaying(false)
        print("Energy checks passed: timer lifecycle, native priority, sleep/wake, multi-display capture, bounded/corrupt artwork, spectrum pause/resume")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-energy-check-') as temp:
    temp = Path(temp)
    (temp / 'Check.swift').write_text(source)
    (temp / 'Spectrum.swift').write_text(spectrum)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(root / 'boringNotch/models/PlaybackState.swift'),
                    str(temp / 'Spectrum.swift'), str(temp / 'Check.swift'), '-o', str(temp / 'check')], env=env, check=True)
    subprocess.run([str(temp / 'check')], check=True)
