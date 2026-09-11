# Apple Music Compact Lyrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute inline in the current conversation; do not dispatch subagents unless the user requests them.

**Goal:** 在闭合灵动岛右侧显示最多三字符的 Apple Music 同步短语，并提供轻量粒子消散和聚合过渡。

**Architecture:** 复用 MusicManager 的播放器状态和歌词获取链路，抽出一个纯数据文件处理 LRC、分段、匹配与时间轴。一个 SwiftUI 视图负责边界唤醒和 Canvas 粒子过渡，ContentView 仅负责槽位及外框布局。

**Tech Stack:** Swift 5 language mode、macOS 14+、SwiftUI、AppKit、NaturalLanguage、Foundation、现有 Defaults 与 URLSession。

**Spec:** `docs/superpowers/specs/2026-09-11-compact-lyrics-design.md`

## Global Constraints

- 保持 macOS 14.0 最低版本，不新增第三方依赖。
- 新设置 `enableCompactLyrics`，默认 false，与已有 `enableLyrics` 独立。
- 中文优先，所有文字均遵守三字符上限；英文长词也必须分段，不宣称符合英文自然阅读节奏。
- 不加入语音识别、在线大模型分词、歌词编辑器、多款动画或常驻粒子引擎。
- 时间戳只是所选歌词源标注的行起点，并非保证与音频绝对精确；无逐词时间戳时句内时间为估算。

## 执行环境和文件边界

仓库根：`/Volumes/MySSD/PROJECT/InterestingNotch/Interesting.Notch`。所有以下相对路径均相对该目录。

当前存在未跟踪的 AppleDouble `._*` 文件；不删除、不暂存、不纳入提交。开始执行前检查当前 Git 状态和本地指令。按 executing-plans/using-git-worktrees 的适用规则选择隔离环境，保留这些未跟踪文件。

生产文件新增仅两个：

| 文件 | 职责 |
| --- | --- |
| `boringNotch/models/CompactLyrics.swift` | 数据类型、候选匹配、LRC、切分、时间轴和纯计算 |
| `boringNotch/components/Music/CompactLyricsView.swift` | 边界调度、字形采样、粒子和稳定文字 |

修改文件：`managers/MusicManager.swift`、`models/Constants.swift`、`components/Settings/SettingsView.swift`、`ContentView.swift`、`Localizable.xcstrings`，前缀均为 `boringNotch/`；注册源文件到 `boringNotch.xcodeproj/project.pbxproj`。仅在验证发现需要时修改 `components/Notch/NotchHomeView.swift`，不顺带重构展开播放器。

验证集中于一个 `scripts/CompactLyricsChecks.swift`，使用 @main 与 Swift assert，不添加测试框架或 app 测试 target。目标函数直接来自生产数据文件，不复制逻辑到脚本。

## Task 1：可测试的歌词时间轴

**Files:** Create `boringNotch/models/CompactLyrics.swift`, `scripts/CompactLyricsChecks.swift`。

**Interfaces:** 下列类型均为 internal，静态函数收进 `enum CompactLyrics`；本任务只使用 Foundation、NaturalLanguage。

```swift
struct LyricLine: Equatable { let time: Double; let text: String }
struct LyricSegment: Equatable, Identifiable {
    let id: Int // sorted timeline index, scoped by lyricsRevision in the view
    let start: Double
    let end: Double
    let text: String
}
// CompactLyrics static functions:
// parseLRC(_ source: String) -> [LyricLine]
// split(_ text: String) -> [String]
// timeline(_ lines: [LyricLine], duration: Double) -> [LyricSegment]
// segment(at position: Double, in segments: [LyricSegment]) -> LyricSegment?
// nextBoundary(after position: Double, in segments: [LyricSegment]) -> Double?
// transitionDuration(for segment: LyricSegment) -> Double
```

- [x] 先创建断言入口，运行并确认因缺少生产接口而失败：

```swift
import Foundation
@main struct CompactLyricsChecks {
    static func main() {
        assert(CompactLyrics.split("歌颂这种平凡") == ["歌颂", "这种", "平凡"])
        assert(CompactLyrics.split("也曾像朋友一样和我诉说") == ["也曾像", "朋友", "一样", "和我", "诉说"])
        let lines = CompactLyrics.parseLRC("[offset:-100]\n[00:01.5][00:03.500]歌颂这种平凡\n[00:05.50]\n[bad]ignored")
        assert(lines.count == 3)
        assert(abs(lines[0].time - 1.4) < 0.000001)
        assert(abs(lines[1].time - 3.4) < 0.000001)
        assert(abs(lines[2].time - 5.4) < 0.000001 && lines[2].text.isEmpty)
        let segments = CompactLyrics.timeline([.init(time: 10, text: "歌颂这种平凡"), .init(time: 20, text: "")], duration: 30)
        assert(segments.count == 3)
        assert(CompactLyrics.segment(at: 9, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂")
        assert(CompactLyrics.segment(at: 11, in: segments)?.text == "这种")
        assert(CompactLyrics.segment(at: 12, in: segments)?.text == "平凡")
        assert(CompactLyrics.segment(at: 13, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂") // backward seek
        assert(abs(CompactLyrics.nextBoundary(after: 10, in: segments)! - 10.8) < 0.000001)
        for input in ["你好，世界！", "abcdefg", "👨‍👩‍👧‍👦你好", "e\u{301}1234"] {
            let result = CompactLyrics.split(input)
            assert(result.allSatisfy { (1...3).contains($0.count) })
            let expected = input.filter { !$0.isWhitespace && !$0.isPunctuation }
            assert(result.joined() == String(expected))
        }
        assert(CompactLyrics.timeline([.init(time: 2, text: "你好")], duration: 3).last?.end == 3)
        print("CompactLyrics checks passed")
    }
}
```

运行命令（后续复用）：

```bash
xcrun swiftc -swift-version 5 boringNotch/models/CompactLyrics.swift scripts/CompactLyricsChecks.swift -o /tmp/interesting-notch-lyrics-checks
/tmp/interesting-notch-lyrics-checks
```

- [x] 实现 LRC：全局 offset 先解析；每行枚举所有时间标签，标签之外为正文。小数使用 Double("0." + fraction)，秒数限定小于 60；非有限时间拒绝。保留空正文，按时间和原序排序，同时间按源顺序拼接正文；负时间裁为零。正则只构造一次。
- [x] 实现分段：先按标点和空白分块，再 NLTokenizer。遍历 tokenizer 没覆盖的字符区间以保留 emoji；不按 UTF16 长度裁剪。优先识别“也曾像”“和我”边界修正，不跨标点；对单字段向右合并至三字，二三字词保留；超长词按三个 Character 切开。每次追加非空片段时断言 count <= 3。
- [x] 实现时间轴与二分定位；严格使用半开区间 `[start,end)`，原行下一标记或 duration 作为上界。核心公式如下，变量在遍历中由当前行、下一行和 split 结果取得：

```swift
let count = parts.reduce(0) { $0 + $1.count }
// ponytail: character-based duration can cut long held notes short; replace with word timestamps when available.
let activeDuration = min(max(0, upperBound - start), max(2, Double(count) * 0.4))
let partStart = start + activeDuration * Double(precedingCount) / Double(count)
let partEnd = start + activeDuration * Double(precedingCount + part.count) / Double(count)
// Skip empty parts/count == 0, non-finite duration, and zero-length intervals before this block.
```

`nextBoundary` 返回严格大于当前位置的最近 start 或 end；无边界返回 nil。过渡时长为 `min(0.280, max(0, segment.end-segment.start)*0.35)`。追加以下断言后重新运行以上命令，要求全部通过。暂停状态由 Task 3/5 集成验证，不把相同函数调用相等当作暂停测试。

```swift
assert(CompactLyrics.parseLRC("[00:01]你\n[00:01]好") == [LyricLine(time: 1, text: "你好")])
assert(CompactLyrics.parseLRC("[offset:-2000]\n[00:01]你").first?.time == 0)
assert(CompactLyrics.parseLRC("[00:99]bad\n[xx:01]bad").isEmpty)
assert(CompactLyrics.timeline([], duration: 10).isEmpty)
assert(CompactLyrics.split("， ！").isEmpty)
assert(CompactLyrics.nextBoundary(after: 30, in: segments) == nil)
```

只将新增的两个文件精确暂存并提交 `feat: add compact lyric segmentation and timeline`。

## Task 2：歌曲匹配、请求失效和设置

**Files:** Modify `CompactLyrics.swift`, `scripts/CompactLyricsChecks.swift`, `MusicManager.swift`, `Constants.swift`, `SettingsView.swift`, `Localizable.xcstrings`, `boringNotch.xcodeproj/project.pbxproj`（此时注册 CompactLyrics.swift）。

**Interfaces:** 在纯数据文件增加 `LyricTrack: Equatable`，字段 `bundleID, title, artist, album: String`、`duration: Double`；增加 LRCLIB 响应 `LyricCandidate: Decodable`，字段 `trackName, artistName: String`、`albumName: String?`、`duration: Double`、`plainLyrics, syncedLyrics: String?`。`CompactLyrics.match(_ candidates: [LyricCandidate], track: LyricTrack) -> LyricCandidate?`。

MusicManager 增加 `@Published private(set) var compactSegments: [LyricSegment] = []` 和 `@Published private(set) var lyricsRevision: UInt64 = 0`；内部保存 `lyricsTask: Task<Void,Never>?`、`lyricsTrack: LyricTrack?`、`lyricsGeneration: UInt64`。新增 `@MainActor private func refreshLyrics()`，读取已经更新的公开播放器属性与两个开关。

- [x] 扩展同一个断言脚本验证匹配：构造歌名 Song、歌手 Singer、专辑 Album、时长 180 的 track，响应 Song Live/180、Song/183、Song/181，只有第三项可选；两个完全匹配候选返回 nil；空歌手返回 nil。使用初始化器创建以下固定数据，再调用 match 断言：

```swift
let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
let good = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 181, plainLyrics: "Hello", syncedLyrics: "[00:01]Hello")
assert(CompactLyrics.match([good], track: track)?.duration == 181)
assert(CompactLyrics.match([good, good], track: track) == nil)
```

- [x] 实现匹配为去除首尾空白、统一大小写后的字段相等，不删除版本描述。title/artist 非空、duration 有限且 > 0；提供专辑时必须相等，缺失专辑时仅在其余条件唯一命中才采用。`abs(candidate.duration-track.duration) <= 2`，同步模式只选有非空 syncedLyrics 的候选；所有条件在 parse 前检查。重复相同响应也保守视作歧义。
- [x] 增加 Defaults key 和设置 Toggle，中文文案“Apple Music 右侧短语歌词”，说明“每次最多三字；按逐行歌词估算词语时间，无同步歌词时显示原有动画”。沿用项目 xcstrings 格式和现有 Defaults.publisher 生命周期，不添加新观察器框架：

```swift
static let enableCompactLyrics = Key<Bool>("enableCompactLyrics", default: false)
// In SettingsView's existing media live activity section:
Defaults.Toggle("Compact lyrics for Apple Music", key: .enableCompactLyrics)
```

执行时核对 Defaults.Toggle 已安装版本的初始化器；若只使用 key + label 模式则照邻近现有代码书写，不更换依赖。两个 Defaults publisher 均在主线程触发 refreshLyrics，复用 cancellables。

- [x] 从 hasContentChange 封面分支移除歌词请求，在 `updateFromPlaybackState` 的属性赋值及 timestampDate 更新之后调用 refreshLyrics。以 track 和请求需求元组 `(expanded,compactAppleMusic)` 去重；设置需求变化允许当前歌曲重新请求，播放位置变化不触发网络。关闭全部需求、控制器重置或歌曲身份变化时取消任务，增加 generation，清空 compactSegments/syncedLyrics/currentLyrics，并增加 lyricsRevision。
- [x] 改写现有歌词获取链路，保留 AppleScript 获取文本能力。先 `/api/get` 按 track_name/artist_name/album_name/duration 查询；无匹配时仅回退一次 `/api/search`。复用 URLSession.shared，URLComponents.queryItems，不在日志输出完整歌词。所有发布，包括 native 纯文本、loading 和失败状态，都先检查 generation：

```swift
lyricsTask?.cancel()
lyricsGeneration &+= 1
let generation = lyricsGeneration
// Inside the owned Task, after each await and immediately before state mutation:
guard !Task.isCancelled, generation == self.lyricsGeneration else { return }
```

网络失败不删除已拿到的本歌 native 纯文本。同步成功后同时更新 currentLyrics、syncedLyrics（保持现有 tuple 接口）、compactSegments 和 lyricsRevision。旧 private parseLRC 删除，统一调用生产解析。`lyricLine(at:)` 在首句前返回空字符串；空标记显示空字符串；不再默认索引零。destroy 与控制器切换时一并取消并失效歌词任务，遵守现有 actor 边界。

- [ ] 重跑纯数据断言。应用集成检查保留到 Task 5：四种开关组合、播放中开关、封面刷新不重复请求、A→B 快速切歌旧结果失效、AppleScript 文本不屏蔽同步查询、离线保留展开纯文本。检查差异后精确暂存本任务文件并提交 `feat: fetch matched synced lyrics for compact mode`。

## Task 3：固定宽度的静态短语槽位

**Files:** Create `components/Music/CompactLyricsView.swift`; modify `ContentView.swift`, project.pbxproj。

**Interfaces:** `CompactLyricsView` 接收 `segments: [LyricSegment]`、`revision: UInt64`、`position: Double`、`sampleDate: Date`、`rate: Double`、`isPlaying: Bool`、`tint: Color`，以及 `@ViewBuilder fallback: () -> Fallback`。使用泛型 Fallback: View，避免 AnyView。数据来自现有 MusicManager 的时间样本，不另建音乐观察模型。

- [x] 添加视图并注册工程；静态视图先完成，不在此任务引入 Canvas。内部当前位置用播放器样本估算：

```swift
let estimated = isPlaying
    ? position + max(0, now.timeIntervalSince(sampleDate)) * rate
    : position
let segment = CompactLyrics.segment(at: max(0, estimated), in: segments)
// Render Text(segment.text) if present, otherwise fallback().
```

将 revision、position、sampleDate、rate、isPlaying 组成小型 Equatable task identity（定义在视图文件内）。`.task(id:)` 立即定位，再睡到 `nextBoundary`，醒来重新从绝对位置计算。rate <= 0、暂停或无未来边界直接结束；任务取消直接退出，禁止捕获取消后继续循环。视图消失由 SwiftUI 取消 task。不要把整个 ContentView 放进 TimelineView。

- [x] 在 ContentView 中增加 `@Default(.enableCompactLyrics)`，条件严格为该开关且 bundleIdentifier == "com.apple.Music"。提取已有频谱/Lottie 内容为一个 @ViewBuilder 属性并作为 fallback 传入；歌词视图不改变现有通知、隐藏及展开优先级。
- [x] 固定三字槽宽使用 NSFont.systemFont(ofSize: 13, weight: .medium) 测量三个全宽字；对实际三字符 cluster 的极端宽度采用单行缩放而非外框扩大。初始水平边距每侧 4 pt，字号视觉下限 10 pt。若复杂 emoji 在下限仍超过宽度，保持整个片段缩放以不裁切，并记录例外，不破坏字符守恒。所有宽度仅由模式和屏幕布局决定，不随当前文本变化。
- [x] 同步更新 `computedChinWidth`。按物理刘海中心保持左右占位等宽：歌词模式两侧均取 `max(originalSideWidth, compactSlotWidth)`，左封面在左槽内保持靠近刘海的原始相对位置；中心黑色覆盖区域不变。不是仅增加 HStack 右宽导致刘海偏移。复用相同宽度计算到音乐 HStack 与轮廓，不复制两个略有不同的公式。

```swift
let font = NSFont.systemFont(ofSize: 13, weight: .medium)
let compactSlotWidth = ceil(("歌颂你" as NSString).size(withAttributes: [.font: font]).width) + 8
let sideWidth = compactMode ? max(originalSideWidth, compactSlotWidth) : originalSideWidth
// Use sideWidth for both closed side slots and computedChinWidth's 2 * sideWidth term.
```

- [ ] 构建后人工检查：一字/三字/emoji、首句前、空行、暂停、前后 seek、开关切换、频谱和自定义 Lottie 回退，窗口中心及 hit area 保持对齐。没有目标应用运行条件时只记录静态检查，不声称 UI 验收通过。提交 `feat: display compact lyrics in the closed notch`。

## Task 4：局部粒子过渡

**Files:** Modify `CompactLyricsView.swift`, `CompactLyrics.swift`（纯过渡时长函数）, `scripts/CompactLyricsChecks.swift`。

**Interfaces:** 视图内部增加 `Particle`，字段 `origin: CGPoint`、`drift: CGVector`、`radius: CGFloat`；`Transition` 保存 outgoing/incoming 字形采样、startedAt 与 duration。不暴露新的管理器。稳定状态始终普通 Text。

- [x] 添加过渡时长边界断言并运行上述 swiftc 命令。函数已在 Task 1 实现，因此本步验证已有实现，不人为制造失败：

```swift
let fast = LyricSegment(id: 0, start: 0, end: 0.1, text: "你")
assert(abs(CompactLyrics.transitionDuration(for: fast) - 0.035) < 0.000001)
let slow = LyricSegment(id: 1, start: 0, end: 2, text: "你好")
assert(CompactLyrics.transitionDuration(for: slow) == 0.280)
```

- [x] 每次新目标由 `(revision, segment.id)` 标识。按实际字体与 Retina scale 使用 AppKit 位图绘制文字，读取 alpha>0 的像素中心，用均匀步长取最多 160 个样本。采样只在目标变化时执行；字形位图尺寸受槽位与字体约束。固定种子的简单生成器或索引函数计算方向，漂移长度 2–5 pt，不调用每帧随机函数。最多保存两个字形，不建无限缓存。
- [x] 只在 Transition 存在时插入 `TimelineView(.animation)` + Canvas。每帧由 startedAt 推导归一化进度，使用以下插值；Canvas 不写 @State，不执行字形采样：

```swift
let p = min(1, max(0, now.timeIntervalSince(startedAt) / duration))
let eased = p * p * (3 - 2 * p)
// outgoing: position = origin + drift * eased; opacity = 1 - eased
// incoming: position = origin + drift * (1 - eased); opacity = eased
// Stable full glyph crossfades with sampled particles; final result is normal Text.
```

正常文字与采样点交接时限制叠加亮度，不让两组完整文本同时强可见。过渡开始可以重叠；完成时销毁 TimelineView，展示普通 Text。用视图拥有的可取消完成任务落回稳定状态；新片段取消旧完成任务并替换状态，过期任务不能清除新过渡。
- [x] `accessibilityReduceMotion` 为 true 使用 100 ms 或片段时长 35% 中较短值淡入淡出，不采样、不创建粒子。暂停允许完成当前过渡但不换词；seek 超过一个片段直接定位目标，后续正常边界再动画；关闭、隐藏、revision 变化均失效旧动画。字形采样失败显示正常 Text，不能空白或崩溃。
- [ ] 重跑纯断言并构建。目视核对真实笔画散开与聚合、快速片段可读、暂停无持续运动、反复跳转没有过渡队列；验证粒子最多 320。提交 `feat: animate compact lyrics with bounded particles`。

## Task 5：构建、实机与交付记录

**Files:** Create `docs/superpowers/validation/2026-09-11-compact-lyrics.md`; only fix scoped implementation defects found by checks。

- [x] 运行纯 Swift 检查，记录命令、退出码及输出。它仅证明数据处理和纯计算，不证明网络生命周期和视觉性能。
- [x] 单次指定已安装 Xcode，查询实际 scheme；当前系统 xcode-select 指向 `/Library/Developer/CommandLineTools`，不修改全局选择：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -list -project boringNotch.xcodeproj
```

选择输出中真实 app scheme（目标名当前为 boringNotch，不把目标名未经核实当 scheme）。下面命令在列表确认 scheme 为 boringNotch 时执行；名称不同则使用列表原值：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/interesting-notch-lyrics-build CODE_SIGNING_ALLOWED=NO build
```

编译通过不代表未签名 app 可正常执行所有权限相关操作。注册文件、依赖下载、构建错误应在本阶段修复；签名和 Apple Music 自动化权限按实际启动方式核实，不擅自改全局权限或终止用户运行实例。

- [ ] 建立五组人工矩阵并记录实际歌曲、版本、歌词来源和观测结果：

| 组 | 具体操作 | 通过条件 |
| --- | --- | --- |
| 开关 | 两开关四组合；播放中开关 | 当前歌曲立即响应，展开歌词独立，关闭全部不继续请求 |
| 身份 | 同名不同版本；快速 A→B；封面刷新；非 Apple Music | 不串词，不被旧请求覆盖；封面不重请求；其他播放器保留原动画 |
| 时间 | 首句前、空标记、暂停/恢复、前后跳转、最后一句 | 无提前首句和过期词队列；跳转后立即定位 |
| 视觉 | 1/3 字、emoji、中英、闭合展开、多屏、通知 | 无裁切和逐词跳宽，物理刘海不露底，通知优先级保持 |
| 故障 | 无歌词、歧义候选、离线、减少动态效果 | 频谱/Lottie 回退，已有本歌纯文本保留，无粒子降级正常 |

- [ ] 慢歌、快歌、长间奏各实测至少 60 秒；使用 Instruments 可用的 Time Profiler/动画帧工具记录设备、屏幕刷新率、动画时 CPU 和帧耗时分布，60 Hz 以 16.7 ms 帧预算为目标。暂停稳定 30 秒、隐藏 30 秒，检查没有来自 CompactLyricsView 的持续粒子更新。与同歌同环境关闭模式对比，不能把网络、系统负载或其他既有动画消耗归因给本功能。没有采样数据就标记性能未验证。
- [ ] 对照 spec 检查覆盖，运行 `git diff --check`；只修复本功能缺陷，不进行无关重构。将验证记录与本阶段修复精确提交 `test: record compact lyrics validation`，交付包含设置入口、实际已过检查、未验证项和已知近似同步限制。

## 自审和交接

覆盖对应：获取/匹配/设置 → Task 2；解析/断句/时间轴 → Task 1；布局/调度/回退 → Task 3；粒子/无障碍/取消 → Task 4；集成与目标机性能 → Task 5。

执行期间先读取每个将修改函数的所有调用方；尤其检查 MusicManager 原歌词消费者和 ContentView 的外框宽度。每任务结束运行对应检查并记录，不以“代码已写”替代“验证通过”。代码片段描述接口和关键实现，不是可直接覆盖现有文件的整文件补丁；集成前阅读完整受影响函数。

实现已完成并提交到 feature/compact-lyrics；纯数据、离屏渲染、受控视图生命周期、完整构建和签名校验通过。真实播放器已观察到短语换词，设置开关已读回。多屏、慢歌/快歌/长间奏各 60 秒的性能矩阵仍待体验验收；未勾选的混合步骤包含这些尚未执行部分。详见 ../validation/2026-09-11-compact-lyrics.md。
