import Foundation

@main struct VideoAudioChecks {
    @MainActor static func main() {
        let youku = "com.youku.mac"
        let running: Set<String> = [youku]
        var remote = PlaybackState(bundleIdentifier: "com.bilibili.bilibiliPC")
        remote.title = "Paused previous video"
        let playing = remote.withVideoAudioFallback(activeSources: [youku], runningSources: running, previous: remote)
        assert(playing.bundleIdentifier == youku && playing.isPlaying && playing.isAudioFallback)
        assert(playing.title.isEmpty && playing.duration == 0 && !playing.isMusicSource)
        let paused = remote.withVideoAudioFallback(activeSources: [], runningSources: running, previous: playing)
        assert(paused.bundleIdentifier == youku && !paused.isPlaying && paused.isAudioFallback)
        let resumed = remote.withVideoAudioFallback(activeSources: [youku], runningSources: running, previous: paused)
        assert(resumed.isPlaying && resumed.bundleIdentifier == youku)
        let exited = remote.withVideoAudioFallback(activeSources: [], runningSources: [], previous: resumed)
        assert(exited.bundleIdentifier.isEmpty && !exited.isPlaying)
        remote.isPlaying = true
        let native = remote.withVideoAudioFallback(activeSources: [youku], runningSources: running, previous: resumed)
        assert(native == remote && !native.isAudioFallback, "Native media must keep priority")
        remote.isPlaying = false
        let unrelated = remote.withVideoAudioFallback(activeSources: [], runningSources: running, previous: remote)
        assert(unrelated == remote, "An open but silent video app must not activate")
        let stable = remote.withVideoAudioFallback(activeSources: ["other.video", youku], runningSources: running, previous: resumed)
        assert(stable.bundleIdentifier == youku, "Concurrent output must not make the icon alternate")
        print("Video audio checks passed: play, pause, resume, exit, native priority and stable selection")
        if CommandLine.arguments.contains("--live") {
            print("Live video main-process output: \(VideoAudioActivity.snapshot())")
        }
    }
}
