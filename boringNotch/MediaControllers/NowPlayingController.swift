//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation
import CoreAudio

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: ""
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?
    private var terminationObserver: AnyCancellable?
    private var terminatedSources = Set<String>()
    private var remotePlaybackState = PlaybackState(bundleIdentifier: "")
    private var videoAudioObserver: AnyCancellable?
    private var videoLifecycleObservers = Set<AnyCancellable>()
    private var videoApplications: [String: pid_t] = [:]
    private var metadataTask: Task<Void, Never>?
    private var metadataURL: URL?
    private var localizedMetadata: LocalizedMusicMetadata?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        terminationObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let source = app.bundleIdentifier else { return }
                self.terminatedSources.insert(source)
                if self.remotePlaybackState.bundleIdentifier == source {
                    self.remotePlaybackState = self.remotePlaybackState.endingPlayback()
                }
                if self.playbackState.bundleIdentifier == source {
                    self.playbackState = self.playbackState.endingPlayback()
                }
            }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshVideoApplications() }
            }.store(in: &videoLifecycleObservers)
        Task { @MainActor [weak self] in
            guard let self else { return }
            NotchMotionEnvironment.shared.$suspended.removeDuplicates()
                .sink { [weak self] _ in
                    // @Published emits before its stored value changes.
                    Task { @MainActor [weak self] in self?.refreshVideoAudio(forceNative: true) }
                }.store(in: &self.videoLifecycleObservers)
            self.refreshVideoApplications()
            await self.setupNowPlayingObserver()
        }

    }

    deinit {
        streamTask?.cancel()
        metadataTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        guard !playbackState.isAudioFallback else { return }
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        guard !playbackState.isAudioFallback else { return }
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        guard !playbackState.isAudioFallback else { return }
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                    await self?.handleAdapterUpdate(update)
                }
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    // MARK: - Update Methods
    @MainActor
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let next = remotePlaybackState.applying(update)
        if terminatedSources.contains(next.bundleIdentifier) {
            // Ignore late MediaRemote events from an exited app, but allow relaunch.
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: next.bundleIdentifier).isEmpty else { return }
            terminatedSources.remove(next.bundleIdentifier)
        }
        remotePlaybackState = next
        refreshLocalizedMetadata()
        refreshVideoAudio(forceNative: true)
    }

    @MainActor
    private func refreshVideoAudio(forceNative: Bool = false) {
        updateVideoPolling()
        guard forceNative || !NotchMotionEnvironment.shared.suspended else { return }
        let videos = remotePlaybackState.isPlaying
            ? [:] : VideoAudioActivity.snapshot(applications: videoApplications)
        var next = remotePlaybackState.withVideoAudioFallback(
            activeSources: videos.filter { $0.value }.map(\.key),
            runningSources: Set(videos.keys), previous: playbackState)
        if next.bundleIdentifier == "com.apple.Music", !next.isAudioFallback,
           let metadata = localizedMetadata, metadata.trackId == next.catalogID {
            next.title = metadata.trackName
            next.artist = metadata.artistName
            next.album = metadata.collectionName
        }
        // Native controls may have optimistic local updates. Polling audio must
        // not overwrite them with an unchanged MediaRemote snapshot.
        guard forceNative || next.isAudioFallback || playbackState.isAudioFallback else { return }
        if next.bundleIdentifier != playbackState.bundleIdentifier || next.isPlaying != playbackState.isPlaying {
            NSLog("Media source: %@ playing=%d audioFallback=%d", next.bundleIdentifier, next.isPlaying, next.isAudioFallback)
        }
        if next != playbackState || next.lastUpdated != playbackState.lastUpdated
            || next.playbackRate != playbackState.playbackRate || next.volume != playbackState.volume {
            playbackState = next
        }
    }
    
    @MainActor
    private func refreshVideoApplications() {
        videoApplications = VideoAudioActivity.applications()
        refreshVideoAudio()
    }

    @MainActor
    private func updateVideoPolling() {
        let needed = !videoApplications.isEmpty && !remotePlaybackState.isPlaying
            && !NotchMotionEnvironment.shared.suspended
        guard needed else { videoAudioObserver = nil; return }
        guard videoAudioObserver == nil else { return }
        // ponytail: poll output IO only for cached video processes lacking native
        // playback events; replace with IO listeners when reliable on all targets.
        videoAudioObserver = Timer.publish(every: 1, tolerance: 0.3, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshVideoAudio() }
            }
    }

    @MainActor
    private func refreshLocalizedMetadata() {
        let url = remotePlaybackState.bundleIdentifier == "com.apple.Music"
            ? remotePlaybackState.catalogID.flatMap { LocalizedMusicMetadata.lookupURL(id: $0) } : nil
        guard url != metadataURL else { return }
        metadataTask?.cancel()
        metadataURL = url
        localizedMetadata = nil
        guard let url, let id = remotePlaybackState.catalogID else { return }
        metadataTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
                guard let self, !Task.isCancelled, self.metadataURL == url,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let metadata = try LocalizedMusicMetadata.decode(data, id: id) else { return }
                self.localizedMetadata = metadata
                self.refreshVideoAudio(forceNative: true)
            } catch {
                // Keep the player's metadata when offline or absent from this storefront.
            }
        }
    }

     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = Data()
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }
            
            // Pipe reads may split a UTF-8 character or a large artwork payload.
            // Decode only complete JSON lines, never individual read chunks.
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty {
                    await processJSONLine(line, as: type, onLine: onLine)
                }
            }
        }
    }
    
    private func processJSONLine<T: Decodable>(_ data: Data, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }
    
    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
    
    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}

// MARK: - Audio-only video presence
// No audio recording or tap: only query whether a video app's main process has output IO.
enum VideoAudioActivity {
    @MainActor static func applications() -> [String: pid_t] {
        guard #available(macOS 14.2, *) else { return [:] }
        var sources: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, let url = app.bundleURL,
                  Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String == "public.app-category.video",
                  !PlaybackState(bundleIdentifier: id).isMusicSource else { continue }
            sources[id] = app.processIdentifier
        }
        return sources
    }

    @MainActor static func snapshot(applications: [String: pid_t]? = nil) -> [String: Bool] {
        guard #available(macOS 14.2, *) else { return [:] }
        // Helpers may keep output IO open while paused; query only main processes.
        return (applications ?? Self.applications()).mapValues { isOutputRunning(pid: $0) }
    }

    @available(macOS 14.2, *)
    static func isOutputRunning(pid: pid_t) -> Bool {
        var pid = pid
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processID) == noErr,
              processID != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
