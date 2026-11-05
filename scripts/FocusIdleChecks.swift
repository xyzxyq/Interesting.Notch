import AppKit
import SwiftUI

@main @MainActor struct FocusIdleChecks {
    static func main() throws {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (seconds, value, unit) in [(0.0, "0", "MIN"), (59, "0", "MIN"), (60, "1", "MIN"),
                                       (900, "15", "MIN"), (3599, "59", "MIN"), (3600, "1.0", "h"),
                                       (5400, "1.5", "h"), (36000, "10.0", "h")] {
            let label = ImmersiveFocus.elapsedLabel(since: start, now: start.addingTimeInterval(seconds))
            assert(label.value == value && label.unit == unit, "Unexpected duration at \(seconds): \(label)")
        }
        assert(ImmersiveFocus.elapsedLabel(since: start, now: start.addingTimeInterval(-60)).value == "0")
        assert(ImmersiveFocus.elapsedLabel(since: start, now: Date(timeIntervalSince1970: .nan)).value == "0")
        var saved = ImmersiveFocus.sessionStart(enabled: true, stored: nil, now: start)
        assert(saved == start)
        saved = ImmersiveFocus.sessionStart(enabled: true, stored: saved, now: start.addingTimeInterval(900))
        assert(saved == start, "Restart/duplicate enable reset the shared start time")
        for (music, playing, idle) in [(true, true, false), (true, false, true),
                                      (false, true, true), (false, false, true)] {
            assert(ImmersiveFocus.presentsIdle(enabled: true, music: music, playing: playing) == idle)
            assert(ImmersiveFocus.presentsMedia(enabled: true, music: music, playing: playing, idle: false) != idle)
            assert(saved == start, "Music availability must not own the session clock")
            assert(!ImmersiveFocus.presentsIdle(enabled: false, music: music, playing: playing))
        }
        saved = ImmersiveFocus.sessionStart(enabled: false, stored: saved)
        assert(saved == nil)
        saved = ImmersiveFocus.sessionStart(enabled: true, stored: saved, now: start.addingTimeInterval(1000))
        assert(saved == start.addingTimeInterval(1000), "Re-enabling must begin a new session")

        for size in [18.0, 24, 26] {
            let renderer = ImageRenderer(content: FocusModeIcon().frame(width: size, height: size))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            var visible = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let pixel = bitmap.colorAt(x: x, y: y)!
                    if pixel.alphaComponent > 0.3 { visible += 1 }
                    if x == 0 || y == 0 || x == bitmap.pixelsWide - 1 || y == bitmap.pixelsHigh - 1 {
                        assert(pixel.alphaComponent < 0.02, "Icon clipped at \(size) points")
                    }
                }
            }
            assert(visible > 100, "Small focus icon lost legibility")
        }
        for minutes in [0.0, 15, 59, 60, 90, 600] {
            let label = FocusDurationLabel(startedAt: start, now: start.addingTimeInterval(minutes * 60))
                .frame(width: 24, height: 24)
            let renderer = ImageRenderer(content: label)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            assert(bitmap.pixelsWide == 48 && bitmap.pixelsHigh == 48)
            var visible = 0
            for y in 0..<48 {
                for x in 0..<48 {
                    if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.3 { visible += 1 }
                    if x == 0 || x == 47 || y == 0 || y == 47 {
                        assert(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.02,
                               "Compact duration clips at \(minutes) minutes")
                    }
                }
            }
            assert(visible > 40, "Compact duration lost its digits or unit")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let preview = VStack(alignment: .leading, spacing: 22) {
            Text("聚焦 · 圆润精修版").font(.system(size: 23, weight: .semibold))
            HStack(spacing: 28) {
                FocusModeIcon().frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 12) {
                    Text("圆润弧面 · 柔和高光 · 玻璃光珠").font(.system(size: 14))
                    HStack(spacing: 14) {
                        FocusModeIcon().frame(width: 24, height: 24)
                        Text("24 pt 实际尺寸").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.035), in: RoundedRectangle(cornerRadius: 22))
            ForEach([15.0, 90], id: \.self) { minutes in
                FocusIdleView(startedAt: Date().addingTimeInterval(-minutes * 60), sideWidth: 24, gap: 188, iconSize: 24)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 15,
                        bottomTrailingRadius: 15, topTrailingRadius: 4))
                    .frame(maxWidth: .infinity)
            }
            Text("分钟累计 · 音乐暂停时显示 · 关闭专注后重置")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(30).frame(width: 480).foregroundStyle(.white).background(Color(white: 0.075))
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("focus-idle-refined.png"))
        print("PASS focus idle: minute/hour boundaries, shared/persistent session start, enable/reset, music/source gates, 18/24/26-point icon rendering")
    }
}
