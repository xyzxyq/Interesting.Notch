<p align="center"><img src="docs/assets/interesting-botch-icon.png" width="160" alt="interesting botch 图标"></p>

<h1 align="center">interesting botch</h1>
<p align="center">让 macOS 灵动岛呈现音乐、Codex 任务与日常状态。</p>

<p align="center">
  <a href="https://github.com/xyzxyq/Interesting.Notch">本项目</a> ·
  <a href="https://github.com/TheBoredTeam/boring.notch">上游 Boring Notch</a> ·
  <a href="LICENSE">GPL-3.0</a>
</p>

## 项目来源

**interesting botch 是基于 [TheBoredTeam/boring.notch（Boring Notch）](https://github.com/TheBoredTeam/boring.notch) fork 后进行二次开发的独立衍生项目，由 [xyzxyq](https://github.com/xyzxyq) 维护。**

原项目及其贡献者提供了灵动岛窗口、音乐控制、文件暂存、日历与系统 HUD 等基础能力。本仓库在这些工作的基础上，继续开发 Codex 状态联动、火箭与液态水滴动画、音乐边缘动效、歌词展示以及相关稳定性修复。感谢上游作者和所有贡献者。

本项目不是 TheBoredTeam 的官方版本，也不是 OpenAI 的官方产品。此 README 描述本 fork；上游的安装包、Homebrew 配方、社区与构建状态不代表本版本。

## 本版本的主要改动

| 功能 | 表现 |
| --- | --- |
| Codex 火箭状态 | 执行任务时将灵动岛呈现为火箭，尾焰与速度效果随思考强度变化。 |
| 交互提醒水滴 | 等待用户交互时，通过液态过渡、弹跳水滴与呼吸灯泡提示用户查看。 |
| 额度与模型信息 | 以燃油表现剩余额度；展开栏显示额度、模型名称及思考强度。Plus 优先展示 5 小时额度，Pro 及以上优先展示周额度。 |
| 音乐与歌词 | 提供环绕轮廓的水波等动效、可选音频强弱响应与紧凑歌词展示，并修复歌词匹配和播放状态相关问题。 |
| 权限与稳定性 | HUD 使用主程序的辅助功能权限；音频响应在后台先检查权限，并提供显式授权与重连入口。 |

Codex 信息由本机桥接脚本读取，显示内容取决于客户端可提供的状态与额度数据；客户端接口变化可能影响兼容性。

## 使用与构建

工程的最低部署目标为 **macOS 14**。源码构建沿用上游的工具要求：**macOS 15.6 或更新版本、Xcode 26 或更新版本**。不同系统版本的音频捕获和媒体能力可能存在差异。

1. 克隆本 fork：
   ```bash
   git clone https://github.com/xyzxyq/Interesting.Notch.git
   cd Interesting.Notch
   ```
2. 打开工程，等待 Swift Package Manager 解析依赖：
   ```bash
   open boringNotch.xcodeproj
   ```
3. 在 Xcode 选择 `boringNotch` scheme，配置自己的签名身份后按 `⌘R` 构建运行。

`interesting botch` 是当前项目展示名称。工程名、内部标识与部分开发构建名称暂时保留 `boringNotch` / `InterestingNotch Development`，以避免重命名影响已有设置和授权。项目图标采用蓝白笑脸与顶部黑色刘海的设计。

如需查找本 fork 的发布包，请查看[本仓库 Releases](https://github.com/xyzxyq/Interesting.Notch/releases)，并核对对应提交及说明；不要使用上游下载链接来获取本 fork 的新增功能。

### Codex 状态桥接

安装本机桥接需要 Python 3，以及可访问的本机 Codex 客户端环境。在仓库根目录执行：

```bash
python3 scripts/codex-notch-bridge-install.py
```

安装脚本会为当前用户注册 LaunchAgent，使桥接独立于终端运行。移除自动启动：

```bash
python3 scripts/codex-notch-bridge-install.py --uninstall
```

## 权限说明

| 功能 | 所需权限 |
| --- | --- |
| 替换音量、亮度等系统 HUD | 辅助功能 |
| 音乐动效跟随音频强弱 | 录屏与系统录音；不授权时仍可使用普通动效 |
| 日历、提醒事项等功能 | 按所用功能分别授权 |

请为实际运行的应用授权。开发版更换签名身份后，系统中已有的开关可能仍对应旧版本；如果开关已开但 HUD 仍提示授权，可在辅助功能列表中移除旧条目，再添加当前应用并重新授权。

持续开发时应保持签名身份与安装路径稳定。本仓库提供 [本机开发签名脚本](scripts/sign-development.py)，用于复用本地私有签名身份；它不会自动授予系统权限或安装证书信任，也不等同于 Apple Developer ID 公证发布。首次使用须自行配置对应的代码签名信任，签名私钥和钥匙串密码不得上传到仓库。

## 贡献与问题反馈

本 fork 的问题请提交到[本仓库 Issues](https://github.com/xyzxyq/Interesting.Notch/issues)，附上 macOS 版本、构建提交、复现步骤及相关日志。提交代码前可阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；其中沿用的上游流程请结合本 fork 的实际情况使用。

## 许可与致谢

本项目保留上游的 **GNU GPL v3** 许可证，完整文本见 [LICENSE](LICENSE)。原项目与第三方代码的版权和归属声明予以保留，第三方许可见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。

- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)：本项目的上游基础。
- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)：媒体播放信息适配。
- [NotchDrop](https://github.com/Lakr233/NotchDrop)：上游文件暂存功能的早期基础。
- [@maxtron95](https://github.com/maxtron95)：上游原始图标设计。本 fork 当前使用另行制作的蓝白笑脸图标。
- [@himanshhhhuv](https://github.com/himanshhhhuv)：上游网站设计。
