import SwiftUI
import ScreenCaptureKit
import AVFoundation

struct EdgeEnergy {
    private(set) var value = 0.0
    mutating func update(rms: Double, dt: Double) -> Double {
        let target = rms.isFinite && rms > 0 ? min(1, max(0, (20 * log10(rms) + 55) / 47)) : 0
        let response = target > value ? 0.10 : 0.65
        value += (target - value) * (1 - exp(-max(0, min(dt, 1)) / response))
        return value
    }
}

@MainActor final class MusicEdgeAudio: NSObject, ObservableObject, @preconcurrency SCStreamOutput, @preconcurrency SCStreamDelegate {
    static let shared = MusicEdgeAudio()
    @Published private(set) var energy = 0.0
    @Published private(set) var status = "未启用音频响应"
    private var stream: SCStream?
    private var task: Task<Void, Never>?
    private var key: String?
    private var meter = EdgeEnergy()
    private var lastSample = Date.distantPast
    private var lastPublished = Date.distantPast

    func configure(bundleID: String?, active: Bool) {
        let next = active ? bundleID : nil
        guard next != key else { return }
        key = next
        task?.cancel()
        let old = stream
        stream = nil; energy = 0; meter = EdgeEnergy()
        status = next == nil ? "未启用音频响应" : "正在连接播放器音频…"
        task = Task {
            if let old { try? await old.stopCapture() }
            guard let next, !Task.isCancelled else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled, key == next else { return }
                guard let app = content.applications.first(where: { $0.bundleIdentifier == next }), let display = content.displays.first else {
                    status = "未找到播放器音频，保持轻柔动效"; return
                }
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000; config.channelCount = 2
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                let capture = SCStream(filter: filter, configuration: config, delegate: self)
                // Only audio output is consumed. No microphone, image frames, files or network upload.
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
                stream = capture
                lastSample = .now; lastPublished = .distantPast
                try await capture.startCapture()
                guard !Task.isCancelled, key == next else { try? await capture.stopCapture(); return }
                status = "已连接音频；静音或受保护内容可能无法响应"
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    if Date.now.timeIntervalSince(lastSample) > 2 {
                        energy = 0
                        status = "暂未收到音频，保持轻柔动效"
                    }
                }
            } catch {
                guard !Task.isCancelled, key == next else { return }
                if let stream { try? await stream.stopCapture() }
                stream = nil; energy = 0
                status = "无法读取音频：请检查系统的屏幕与系统音频录制权限"
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream === stream else { return }
        task?.cancel()
        self.stream = nil
        energy = 0; meter = EdgeEnergy()
        status = "音频连接中断，保持轻柔动效；重新打开音频响应可连接"
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .audio, CMSampleBufferIsValid(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let info = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              info.mFormatID == kAudioFormatLinearPCM, info.mBitsPerChannel == 32,
              info.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        var required = 0
        var retained: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &required,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retained)
        guard required >= MemoryLayout<AudioBufferList>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retained) == noErr else { return }
        var sum = 0.0; var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                let x = Double(samples[i])
                if x.isFinite { sum += x * x; count += 1 }
            }
        }
        guard count > 0 else { return }
        let now = Date.now
        let rms = sqrt(sum / Double(count))
        let level = meter.update(rms: rms, dt: now.timeIntervalSince(lastSample))
        lastSample = now
        if now.timeIntervalSince(lastPublished) >= 1.0 / 30 {
            energy = level; lastPublished = now
            status = rms > 0.0001 ? "正在随播放器音量强弱响应" : "音频静音或不可捕获，保持轻柔动效"
        }
    }
}
