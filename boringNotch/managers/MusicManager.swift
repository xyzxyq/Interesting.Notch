//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import ImageIO
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published private(set) var isMusicSource = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published private(set) var lyricsStatus = "Lyrics idle"
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published private(set) var compactSegments: [LyricSegment] = []
    @Published private(set) var lyricsRevision: UInt64 = 0
    private var lyricsTask: Task<Void, Never>?
    private var lyricsTrack: LyricTrack?
    private var lyricsDemand = 0
    private var lyricsGeneration: UInt64 = 0
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .merge(with: Defaults.publisher(.enableCompactLyrics))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLyrics(force: true) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLyrics(force: true) }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        invalidateLyrics()
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        invalidateLyrics()
        bundleIdentifier = nil
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak controller] state in
                    guard let self = self, let controller,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        if state.bundleIdentifier.isEmpty {
            // Source disappearance ends activity; video sources still use the
            // upstream app-artwork and visualizer presentation.
            debounceIdleTask?.cancel()
            lyricsTask?.cancel()
            lyricsGeneration &+= 1
            lyricsTrack = nil
            isFetchingLyrics = false
            elapsedTime = estimatedPlaybackPosition(at: Date())
            timestampDate = Date()
            playbackRate = 0
            isPlaying = false
            isMusicSource = false
            isPlayerIdle = true
            lyricsStatus = "Lyrics idle"
            return
        }
        if isMusicSource != state.isMusicSource { isMusicSource = state.isMusicSource }
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            if state.isMusicSource { self.triggerFlipAnimation() }

            if !state.isMusicSource {
                if bundleChanged || !usingAppIconForArtwork {
                    usingAppIconForArtwork = true
                    updateAlbumArt(newAlbumArt: AppIconAsNSImage(for: state.bundleIdentifier) ?? defaultImage)
                }
            } else if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            // Remember metadata even when two tracks share the same artwork.
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if CompactLyrics.displayText(state.title) != self.songTitle {
            self.songTitle = CompactLyrics.displayText(state.title)
        }

        if CompactLyrics.displayText(state.artist) != self.artistName {
            self.artistName = CompactLyrics.displayText(state.artist)
        }

        if CompactLyrics.displayText(state.album) != self.album {
            self.album = CompactLyrics.displayText(state.album)
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        if self.timestampDate != state.lastUpdated { self.timestampDate = state.lastUpdated }
        refreshLyrics()
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func invalidateLyrics() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsGeneration &+= 1
        lyricsTrack = nil
        lyricsDemand = 0
        currentLyrics = ""
        syncedLyrics = []
        compactSegments = []
        isFetchingLyrics = false
        lyricsStatus = "Lyrics idle"
        lyricsRevision &+= 1
    }

    @MainActor
    private func refreshLyrics(force: Bool = false, useCache: Bool = true) {
        let compact = Defaults[.enableCompactLyrics]
        let demand = isMusicSource ? (Defaults[.enableLyrics] ? 1 : 0) + (compact ? 2 : 0) : 0
        let track = LyricTrack(bundleID: bundleIdentifier ?? "", title: songTitle,
                               artist: artistName, album: album, duration: songDuration)
        let sameTrack = lyricsTrack.map {
            $0.bundleID == track.bundleID && $0.title == track.title && $0.artist == track.artist
                && $0.album == track.album && $0.isReady == track.isReady && abs($0.duration - track.duration) < 1
        } ?? false
        guard force || demand != lyricsDemand || !sameTrack else { return }
        // A metadata change invalidates every publication from earlier requests.
        // Artwork and playback position are intentionally not part of this identity.
        if lyricsDemand != 0 || lyricsTrack != nil { invalidateLyrics() }
        lyricsDemand = demand
        lyricsTrack = track
        guard demand != 0, !track.bundleID.isEmpty, !track.title.isEmpty else { return }
        guard track.isReady else {
            lyricsStatus = "等待歌曲名称、歌手和时长信息"
            return
        }
        isFetchingLyrics = true
        lyricsStatus = "Loading lyrics…"
        let generation = lyricsGeneration
        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.lyricsGeneration { self.isFetchingLyrics = false }
            }
            if !compact && track.bundleID == "com.apple.Music" {
                let native = await Self.nativeLyrics(for: track)
                guard !Task.isCancelled, generation == self.lyricsGeneration else { return }
                self.currentLyrics = CompactLyrics.displayText(native)
                if !native.isEmpty { self.lyricsStatus = "Plain lyrics available"; return }
            }
            do {
                let result = try await LyricsRepository.fetch(track, requireSynced: compact, useCache: useCache)
                guard !Task.isCancelled, generation == self.lyricsGeneration else { return }
                if let result {
                    self.publishLyrics(result.candidate, track: track, compact: compact,
                                       origin: result.cached ? "本地缓存" : result.candidate.source ?? "在线")
                    if result.cacheError { self.lyricsStatus += " · 缓存保存失败" }
                } else {
                    self.lyricsStatus = "未找到匹配的同步歌词"
                    NSLog("Lyrics: no matching timeline")
                }
            } catch {
                guard !Task.isCancelled, generation == self.lyricsGeneration else { return }
                self.isFetchingLyrics = false
                NSLog("Lyrics request failed: %@", String(describing: error))
                guard let delay = CompactLyrics.retryDelay(for: error) else {
                    self.lyricsStatus = "Lyrics request failed"
                    return
                }
                self.lyricsStatus = "歌词服务连接失败，60 秒后自动重试"
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, generation == self.lyricsGeneration else { return }
                self.refreshLyrics(force: true)
            }
        }
    }

    @MainActor
    func retryLyrics() {
        refreshLyrics(force: true, useCache: false)
    }

    var currentLyricTrack: LyricTrack {
        LyricTrack(bundleID: bundleIdentifier ?? "", title: songTitle, artist: artistName, album: album, duration: songDuration)
    }

    @MainActor
    private func publishLyrics(_ candidate: LyricCandidate, track: LyricTrack, compact: Bool, origin: String) {
        let lines = CompactLyrics.parseLRC(candidate.syncedLyrics ?? "").map {
            LyricLine(time: $0.time, text: CompactLyrics.displayText($0.text))
        }
        let plain = CompactLyrics.displayText(candidate.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        currentLyrics = lines.isEmpty ? plain : lines.map(\.text).joined(separator: "\n")
        syncedLyrics = lines.map { ($0.time, $0.text) }
        compactSegments = compact ? CompactLyrics.timeline(lines, duration: track.duration) : []
        lyricsRevision &+= 1
        lyricsStatus = (lines.isEmpty ? "普通歌词已就绪" : "同步歌词已就绪") + " · " + origin
        NSLog("Lyrics loaded: %d lines (%@)", lines.count, origin)
    }

    @MainActor
    func chooseLyrics(_ candidate: LyricCandidate, for track: LyricTrack) throws {
        guard currentLyricTrack == track, LyricsRepository.usable(candidate, track: track) else {
            throw NSError(domain: "LyricsSelection", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "歌曲已切换，或文件没有可用的同步时间戳。请重新打开歌词选择。"])
        }
        try LyricsStore().save(candidate, for: track, manual: true)
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsGeneration &+= 1
        isFetchingLyrics = false
        publishLyrics(candidate, track: track, compact: Defaults[.enableCompactLyrics],
                      origin: "已记住选择 · " + (candidate.source ?? "本地"))
    }

    private static func nativeLyrics(for track: LyricTrack) async -> String {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return "" }
        // Return identity with text: Music may have changed tracks before our poll arrives.
        let script = """
        tell application "Music"
            if it is running then
                try
                    if player state is playing or player state is paused then
                        set t to current track
                        return {name of t, artist of t, album of t, lyrics of t}
                    end if
                end try
            end if
            return {}
        end tell
        """
        guard let result = try? await AppleScriptHelper.execute(script), result.numberOfItems == 4,
              let title = result.atIndex(1)?.stringValue,
              let artist = result.atIndex(2)?.stringValue,
              let album = result.atIndex(3)?.stringValue,
              CompactLyrics.normalized(title) == CompactLyrics.normalized(track.title),
              CompactLyrics.normalized(artist) == CompactLyrics.normalized(track.artist),
              CompactLyrics.normalized(album) == CompactLyrics.normalized(track.album) else { return "" }
        return result.atIndex(4)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx: Int?
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return idx.map { syncedLyrics[$0].text } ?? ""
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let source = CGImageSourceCreateWithData(artworkData as CFData, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 512,
                   kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                let artworkImage = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
                artworkImage.addRepresentation(NSBitmapImageRep(cgImage: thumbnail))
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isMusicSource, self.artworkData == artworkData else { return }
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                do { try await Task.sleep(for: .seconds(Defaults[.waitInterval])) }
                catch { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isMusicSource && isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
