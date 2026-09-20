# 2026-09-20：瞬时提示衔接与歌词渲染优化

> 以下为发布前的开发与验证记录；相关改动纳入 [3.0.9](releases/3.0.9.md)，文中的临时路径和进程状态仅对应当时环境。

## 修改

- HUD 与电池通知一次发布完整呈现状态，复用 0.46 秒弹簧过渡；减少动态效果时使用 0.18 秒淡变。HUD 超时退场保留原内容，不再先切换为音乐。
- 提示头部按进入内容的尺寸布局，退出内容淡出时不再占住旧宽度。固定尺寸修饰器保留稳定视图身份，覆盖收起、展开、内联 HUD 和普通 HUD。
- 电池监听改为一次发送完整 IOKit 快照，删除每个字段延迟一秒的事件队列。相同快照不发布；拔电时不会再被稍后的“不充电”事件覆盖。
- 歌词使用 Canvas symbols 保留文字绘制列表，避免每帧重新排版；歌词帧率、字体、颜色、位移、消散与音乐边缘效果不变。
- 设置页直接读取 `Brand.releaseName = "Super Rocket 🚀"`，不再读取可能留有 Flying Rabbit 的旧偏好值。版本号仍为 3.0.8 / 308。

## 定位证据与范围

原运行实例为 `/Applications/Interesting Notch.app`。5 秒 `sample` 中，歌词 `GraphicsContext.draw(Text...)` 下出现 `NSAttributedString` 测量与 `CTLineCreateWithAttributedString`。优化后的 5 秒样本未再出现该文字排版调用。

Python 常驻 Codex 桥接在两次进程快照中均为 0.0% CPU；其他 Python 文件主要用于检查、打包、签名和安装。本轮没有把它们重写为 Rust：现场证据指向 SwiftUI 绘制，语言替换不能消除这条热点。

## 验证

- Debug 与 Release 编译成功；本地开发签名与 `codesign --verify --deep --strict` 通过。
- `python3 scripts/check-transient.py`：修改前复现一次 HUD 发布 4 次；修改后检查原子发布、旧计时器取消、退场类型保留，以及音乐/HUD/电池/展开头部的目标尺寸。电池覆盖充电、充满、拔电、暂停充电、低电量模式和相同快照无更新。
- `python3 scripts/check-energy.py`、`python3 scripts/check-music-idle.py`、`python3 scripts/BrandLocalizationChecks.py` 通过。
- `CompactLyricsChecks.swift` 完整视觉与运行时检查通过，覆盖暂停、继续、定位、曲终回退、旧句消散、入口过渡。修改前后月球歌词及句间切换两组 PNG 字节完全一致。
- 现有离屏渲染检查每轮 120 帧：单次基线 median 0.252 ms / p95 0.596 ms；单次修改后 median 0.115 ms / p95 0.146 ms。这不是屏幕帧率或可靠的整体加速比例。

| 同一设置域的 Release 实例 | 有效 CPU 样本 | 平均 CPU | 峰值 CPU | top MEM |
| --- | ---: | ---: | ---: | --- |
| 修改前，已运行约 5 小时 | 11 | 13.90% | 15.6% | 164–168 MB |
| 修改后，重新启动 | 20 | 12.33% | 13.1% | 118–122 MB |

`top` 每秒采样，首个累计样本剔除。歌曲进度、进程缓存与运行时长不同；以上只能作为现场观察，不能据此宣称确定的 CPU、内存或电池续航改善。未测量实际功耗。

桌面截图接口返回 `SCStreamErrorDomain -3811`，所以真实键盘操作和充电器插拔的视觉观感仍需人工确认；可运行状态与布局测试不能替代该确认。

## 复现歌词检查

独立编译时移除 `NotchShape.swift` 中的 `#Preview` 块（保留 Shape 与 NotchMotionEnvironment），避免独立 swiftc 的预览宏插件环境问题。然后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 5 -D VISUAL_CHECKS \
  boringNotch/models/PlaybackState.swift boringNotch/models/CompactLyrics.swift \
  boringNotch/models/NotchWeather.swift boringNotch/managers/NotchWeatherManager.swift \
  /tmp/notch-20260920-baseline/NotchShape.swift \
  boringNotch/components/Music/CompactLyricsView.swift scripts/CompactLyricsChecks.swift \
  -o /tmp/notch-lyrics-after
/tmp/notch-lyrics-after
```

本地试用包：`/Users/zxy/Applications/InterestingNotch Optimized.app`；使用与原 Release 相同的设置域，保留 `/Applications/Interesting Notch.app` 供恢复。此包使用已有本地开发签名，未更改公共发布版本。
