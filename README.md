<p align="center">
  <img src="docs/assets/interesting-botch-icon.png" width="96" alt="Interesting Notch 蓝白笑脸图标">
</p>
<h1 align="center">Interesting Notch</h1>
<p align="center"><strong>歌词在流动，任务有回音。</strong></p>
<p align="center">把音乐、Codex 任务与日常状态，放进 macOS 顶部的一小块空间。</p>

<p align="center">
  <a href="https://github.com/xyzxyq/Interesting.Notch/releases/latest"><img src="https://img.shields.io/github/v/release/xyzxyq/Interesting.Notch?style=flat-square&amp;color=3979F6&amp;label=release" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-222222?style=flat-square" alt="macOS 14 或更新版本">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-222222?style=flat-square" alt="Apple Silicon arm64">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-222222?style=flat-square" alt="GPL-3.0"></a>
</p>
<p align="center">
  <a href="https://github.com/xyzxyq/Interesting.Notch/releases/latest"><strong>下载应用</strong></a> &nbsp; / &nbsp;
  <a href="#开始使用">安装与设置</a> &nbsp; / &nbsp;
  <a href="docs/guide.md">使用指南</a> &nbsp; / &nbsp;
  <a href="https://github.com/xyzxyq/Interesting.Notch/issues">反馈问题</a>
</p>

<p align="center"><img src="docs/assets/codex-completion.gif" width="720" alt="Codex 任务运行时灵动岛化作火箭，结束时尾焰熄灭、彩带散开"></p>
<p align="center"><sub>运行时是一枚火箭，结束时留下一次轻巧的庆祝。原生组件演示，非桌面录屏。</sub></p>

## 音乐，留在视线边缘

封面、逐句歌词与昼夜日月装饰，在紧凑布局中一起呈现。展开灵动岛即可控制播放；收起后，当前歌词继续流动。

<p align="center"><img src="docs/assets/lyrics-colors.png" width="640" alt="紧凑歌词的自动配色、自选绿色与彩虹渐变效果"></p>

歌词可选自动配色、自选单色或彩虹渐变；边缘可选黑、白、彩色水波，以及涟漪、星尘、流星和光雾。开启音频响应后，支持的播放器可让动效随声音强弱变化；也可以只保留轻柔的常驻水波。

<details>
<summary><strong>看水波与流星演示</strong></summary>
<p align="center"><img src="docs/assets/music-edge.gif" width="640" alt="彩色水波和流星围绕灵动岛运动，使用模拟音乐能量"></p>
</details>

## 任务有进展，也有提醒

Codex 开始工作时，灵动岛化作火箭；需要你回答时，一颗深色水滴落下。多个请求合并呈现，点击水滴即可查看问题、选择选项或输入回答。

<table>
<tr>
<td width="50%" valign="top">
<h3>工作中的火箭</h3>
<img src="docs/assets/codex-rocket-states.png" width="440" alt="普通灵动岛向火箭过渡，以及不同思考强度的尾焰形态">
<p>思考强度影响尾焰与速度效果。所有运行任务结束后，尾焰熄灭，彩带散开。</p>
</td>
<td width="50%" valign="top">
<h3>等待你的水滴</h3>
<img src="docs/assets/codex-droplet.gif" width="440" alt="待回答提醒落下，新请求与已有水滴融合">
<p>仍有任务运行时，火箭与水滴可以同时出现。清空提醒仅隐藏本地提示，不会取消任务。</p>
</td>
</tr>
</table>

燃油图标展示**剩余额度**，不是输出速度；Plus 优先展示 5 小时额度，Pro 及以上优先展示周额度。需要完整核对的批准类请求仍在 Codex 中处理。

## 日常操作，自然接入

音量、亮度和充电提示沿用灵动岛的外形与布局；音乐控制、文件暂存、日历与摄像头预览延续上游能力。常用操作集中在顶部，按需展开。

<details>
<summary><strong>一个可选的小细节：纸飞机指针</strong></summary>
<p align="center"><img src="docs/assets/paper-plane.gif" width="560" alt="黑色折纸指针在 75% 至 175% 之间调整大小"></p>

在 **设置 → 外观 → 鼠标指针** 中开启，默认关闭。它替换普通箭头，可调大小，关闭后恢复。此实验性功能依赖私有系统接口，兼容范围、颜色冲突与恢复方式见[使用指南](docs/guide.md#纸飞机指针实验性)。

</details>

<sub>本页动效来自项目原生 SwiftUI / Canvas 组件，使用演示状态及模拟音乐能量，不代表真实任务录屏、音频响应或跨应用兼容性验证。GIF 可用 <code>./scripts/render-readme-demos.sh</code> 重建。</sub>

## 开始使用

**Apple Silicon（M 系列） · macOS 14 或更新版本。** 当前发布附件不包含 Intel 安装包。

1. 从 [Releases](https://github.com/xyzxyq/Interesting.Notch/releases/latest) 下载 `arm64.dmg`，退出旧版应用。
2. 打开 DMG，将 **Interesting Notch.app** 拖入 **Applications**，从应用程序文件夹启动。
3. 打开 **设置 → 媒体**，选择“自动跟随正在播放的应用”，按喜好开启滚动歌词与音乐边缘动效。

> 安装包使用本地开发证书签名，尚未经过 Apple Developer ID 公证。若首次打开被 macOS 阻止，请核对下载来源，再使用系统提供的“仍要打开”入口；发布页提供 `SHA256SUMS.txt` 用于校验。

3.0.7 及以后的版本支持在设置中检查更新；自动下载安装默认关闭，由你选择。3.0.6 及更早版本需手动升级一次。内部标识沿用上游，不建议与上游原版同时运行；Debug 使用独立的 Preview 标识。

### 可选：连接 Codex

从同一发布页下载 `codex-bridge.zip`，解压后在解压目录执行：

```bash
python3 scripts/codex-notch-bridge-install.py --binary ./codex-notch-bridge
```

随后在应用的媒体设置中开启 Codex 模式。附件内含 arm64 Swift 可执行文件；Python 3 仅用于安装，日常桥接通过当前用户的 LaunchAgent 独立运行。安装脚本会校验签名、试运行，并在启动失败时恢复旧配置。

**旧 Python 桥接也通过此命令迁移；应用内更新不会更新独立桥接。** 桥接读取本机任务状态、待回答问题与额度，通过带令牌保护的回环接口发送回答；客户端私有接口变化可能影响兼容性。[安装、卸载与接口说明 →](docs/guide.md#codex-状态桥接)

3.0.11 的桥接兼容 Codex 新版内置程序路径。若任务正常显示、燃油图标却长期变成问号，请安装同一发布页的新版桥接附件。

### 播放器与权限

| 功能 | 支持范围与使用条件 |
| :--- | :--- |
| 音乐与歌词 | Apple Music、网易云音乐通过系统播放信息同步；网易云 3.1.9 曾在本机验证。其他播放器需提供完整元数据与进度，QQ 音乐、酷狗尚未专项验证。 |
| 歌词匹配 | 本地缓存、LRCLIB、网易云与手动 LRC 导入；当前为逐句同步。匹配不准确时，用“选择或导入歌词…”预览并保存正确版本。 |
| 音频响应 | 按需申请录屏与系统录音权限；不授权仍可使用普通动效。 |
| 系统 HUD 与日常功能 | 替换音量、亮度 HUD 需要辅助功能权限；日历、摄像头等按所用功能申请。 |

[歌词纠错与缓存](docs/guide.md#歌词获取与纠错) · [权限处理](docs/guide.md#权限与签名)

## 开发与设计

使用 **Xcode 26+**，应用部署目标为 **macOS 14**；Xcode 本身需要兼容的 macOS 版本。

```bash
git clone https://github.com/xyzxyq/Interesting.Notch.git
cd Interesting.Notch
open boringNotch.xcodeproj
```

等待 Swift Package Manager 解析依赖，选择 `boringNotch` scheme，配置自己的签名身份，按 `⌘R` 运行。工程名及部分内部标识保留上游名称，以保持设置与授权兼容。

动画优化优先减少重复计算、无效唤醒与互相竞争的过渡。持续绘制采用受限帧率，适配低电量模式、屏幕休眠和“减少动态效果”。性能记录区分计算基准、离屏绘制与现场观察；**目前没有整机功耗或续航提升的测量结论。**

| 资料 | 内容 |
| :--- | :--- |
| [Super Rocket · 3.0.11](docs/releases/3.0.11.md) | 动效打磨、燃料图标修复与[发布验证](docs/releases/3.0.11-validation.md) |
| [动效打磨与验证](docs/motion-2026-09-26.md) | 手势、过渡、滚动标题与动画生命周期的详细记录 |
| [性能优化记录](docs/performance-round2-2026-09-20.md) | 水波几何、歌词定位与后台查询；另见 [HUD 优化](docs/performance-2026-09-20.md) |
| [原生桥接](docs/native-codex-bridge.md) | Swift 桥接方案、接口及验证 |
| [更新与发布](docs/automatic-updates.md) | 签名更新通道与发布流程 |

## 贡献与致谢

Interesting Notch 基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 二次开发，由 [xyzxyq](https://github.com/xyzxyq) 维护。**这是独立衍生项目，不是上游或 OpenAI 的官方版本。** 安装包与更新通道独立于上游。

提交问题时，请附 macOS 版本、应用版本和复现步骤；参与开发请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

感谢 **Boring Notch** 及其贡献者提供窗口、音乐控制、文件暂存、日历与 HUD 基础；感谢 [LyricsX / LyricsKit](https://github.com/ddddxxx/LyricsX)、[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) 与 [NotchDrop](https://github.com/Lakr233/NotchDrop) 的开源工作。上游原始图标由 [@maxtron95](https://github.com/maxtron95) 设计，网站由 [@himanshhhhuv](https://github.com/himanshhhhuv) 设计；本 fork 使用另行制作的蓝白笑脸图标。

本项目采用 **[GNU GPL v3](LICENSE)**。歌词相关参考与 MPL-2.0 声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，其他依赖许可见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
