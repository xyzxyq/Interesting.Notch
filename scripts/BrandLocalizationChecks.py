#!/usr/bin/env python3
"""Small regression checks for the public Interesting Notch brand and settings locale."""

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = json.loads((ROOT / "boringNotch/Localizable.xcstrings").read_text())
BRAND_TABLES = {
    locale: (ROOT / f"boringNotch/{locale}.lproj/Brand.strings").read_text()
    if (ROOT / f"boringNotch/{locale}.lproj/Brand.strings").exists() else ""
    for locale in ("en", "zh-Hans")
}


def zh(key: str) -> str:
    try:
        return CATALOG["strings"][key]["localizations"]["zh-Hans"]["stringUnit"]["value"]
    except KeyError as error:
        raise AssertionError(f"Missing Simplified Chinese localization: {key}") from error


def brand(locale: str, key: str) -> str:
    match = re.search(rf'^"{re.escape(key)}"\s*=\s*"(.*)";$', BRAND_TABLES[locale], re.MULTILINE)
    assert match, f"Missing {locale} Brand localization: {key}"
    return match.group(1)


def main() -> None:
    project = (ROOT / "boringNotch.xcodeproj/project.pbxproj").read_text()
    assert 'INFOPLIST_KEY_CFBundleDisplayName = "Interesting Notch";' in project
    assert 'INFOPLIST_KEY_CFBundleDisplayName = "Interesting Notch Preview";' in project
    assert 'PRODUCT_NAME = "Interesting Notch";' in project
    info = plistlib.loads((ROOT / "boringNotch/Info.plist").read_bytes())
    assert info["CFBundleName"] == "Interesting Notch"

    public_sources = [
        ROOT / "boringNotch/boringNotchApp.swift",
        ROOT / "boringNotch/menu/StatusBarMenu.swift",
        ROOT / "boringNotch/components/Settings/SettingsWindowController.swift",
        ROOT / "boringNotch/components/Onboarding/WelcomeView.swift",
        ROOT / "boringNotch/components/Onboarding/OnboardingView.swift",
        ROOT / "boringNotch/components/Notch/BoringExtrasMenu.swift",
    ]
    for path in public_sources:
        source = path.read_text()
        assert "Boring Notch" not in source, f"Legacy brand remains in {path.relative_to(ROOT)}"
        assert "TheBoredTeam/boring.notch" not in source, f"Legacy link remains in {path.relative_to(ROOT)}"
    app_source = (ROOT / "boringNotch/boringNotchApp.swift").read_text()
    assert 'DispatchQueue.main.async { NSApp.mainMenu?.items.first?.title = Brand.localized("Interesting Notch") }' in app_source

    for path in [
        ROOT / "boringNotch/components/Settings/SettingsView.swift",
        ROOT / "boringNotch/components/Music/LyricsPicker.swift",
        ROOT / "boringNotch/components/Settings/SoftwareUpdater.swift",
        ROOT / "boringNotch/managers/PaperPlanePointer.swift",
    ]:
        assert not re.search(r"[\u4e00-\u9fff]", path.read_text()), f"Hard-coded Chinese remains in {path.relative_to(ROOT)}"

    settings = (ROOT / "boringNotch/components/Settings/SettingsView.swift").read_text()
    settings = "\n".join(line for line in settings.splitlines() if not line.lstrip().startswith("//"))
    for raw_value_label in ("Text(opt.rawValue)", "Text(style.rawValue)", "Text(option.rawValue)"):
        assert raw_value_label not in settings, f"Unlocalized settings option remains: {raw_value_label}"
    literals = re.findall(r'(?:Text|Toggle|Picker|Button|Label|navigationTitle)\s*\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"', settings)
    for key in literals:
        if key and not re.search(r"[\u4e00-\u9fff]", key) and "\\(" not in key:
            zh(key)

    for key in [
        "Interesting Notch",
        "Paper-plane pointer",
        "Choose or import lyrics…",
        "Retry fetching lyrics",
    ]:
        assert brand("en", key), f"Empty English localization: {key}"
        assert brand("zh-Hans", key), f"Empty Simplified Chinese localization: {key}"

    assert brand("zh-Hans", "Interesting Notch") == "Interesting Notch"

    assert zh("Choose between your system accent color or customize it with your own selection.")

    # Every user-facing setting uses Chinese on a Simplified Chinese system.
    # Product and service names (for example, GitHub, Safari, Apple Music) are
    # deliberately excluded from this list.
    settings_zh = {
        "HUDs": "屏幕提示",
        "Advanced": "高级",
        "Show menu bar icon": "显示菜单栏图标",
        "Preferred display": "首选显示器",
        "Notch height on notch displays": "刘海屏上的刘海高度",
        "Match real notch height": "匹配真实刘海高度",
        "Match menu bar height": "匹配菜单栏高度",
        "Notch height on non-notch displays": "非刘海屏上的刘海高度",
        "Notch sizing": "刘海尺寸",
        "Change media with horizontal gestures": "使用水平手势切换媒体",
        "Enable haptic feedback": "启用触觉反馈",
        "Hover delay": "悬停延迟",
        "Open notch on hover": "悬停时展开刘海",
        "Notch behavior": "刘海行为",
        "Two-finger swipe up on notch to close, two-finger swipe down on notch to open when **Open notch on hover** option is disabled": "在刘海区域双指向上滑动可收起；关闭“悬停时展开刘海”后，双指向下滑动可展开。",
        "Replace system HUD": "替换系统屏幕提示",
        "Replaces the standard macOS volume, display brightness, and keyboard brightness HUDs with a custom design.": "使用自定义设计替换 macOS 标准的音量、显示器亮度和键盘亮度屏幕提示。",
        "Accessibility access is required to replace the system HUD.": "替换系统屏幕提示需要辅助功能权限。",
        "Option key behaviour": "Option 键行为",
        "Progress bar style": "进度条样式",
        "Tint progress bar with accent color": "使用强调色为进度条着色",
        "Show HUD in open notch": "在展开的刘海中显示屏幕提示",
        "Show percentage": "显示百分比",
        "Open Notch": "展开的刘海",
        "Closed Notch": "收起的刘海",
        "Show music live activity": "显示音乐实时动态",
        "Show sneak peek on playback changes": "播放状态变化时显示预览",
        "Sneak Peek Style": "预览样式",
        "Full screen behavior": "全屏时的行为",
        "Hide for all apps": "所有应用全屏时隐藏",
        "Hide for media app only": "仅媒体应用全屏时隐藏",
        "Show lyrics below artist name": "在歌手名称下方显示歌词",
        "Customize which controls appear in the music player. Volume expands when active.": "自定义音乐播放器中显示的控制项；音量控制会在使用时展开。",
        "Hide all-day events": "隐藏全天事件",
        "Auto-scroll to next event": "自动滚动到下一个事件",
        "Always show full event titles": "始终显示完整事件标题",
        "Expanded drag detection area": "扩大拖放检测区域",
        "Copy items on drag": "拖放时复制项目",
        "Remove from shelf after dragging": "拖放后从搁架移除",
        "Quick Share Service": "快速共享服务",
        "Files dropped on the shelf will be shared via this service": "拖放到搁架的文件将通过此服务共享",
        "Quick Share": "快速共享",
        "Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.": "选择从搁架共享文件时使用的服务。点击搁架按钮选择文件，或将文件拖到搁架后立即共享。",
        "Show settings icon in notch": "在刘海中显示设置图标",
        "Colored spectrogram": "彩色频谱图",
        "Show cool face animation while inactive": "未活动时显示趣味表情动画",
        "System": "系统",
        "Custom": "自定义",
        "Using System Accent": "使用系统强调色",
        "Your macOS system accent color": "你的 macOS 系统强调色",
        "Color Presets": "颜色预设",
        "Pick a Color": "选择颜色",
        "Choose any color": "选择任意颜色",
        "Window Appearance": "窗口外观",
        "Hide title bar": "隐藏标题栏",
        "Show notch on lock screen": "在锁定屏幕显示刘海",
        "Hide from screen recording": "在屏幕录制时隐藏",
        "Window Behavior": "窗口行为",
        "HUD style": "屏幕提示样式",
        "Reset to Defaults": "恢复默认设置",
        "Clear slot": "清除位置",
        "Layout Preview": "布局预览",
        "Drag items in the preview to reorder or drop from the palette": "在预览中拖动项目以重新排序，或从控制项面板拖入",
        "Drag a control onto a slot": "将控制项拖到一个位置",
    }
    for key, value in settings_zh.items():
        assert zh(key) == value, f"Unexpected Simplified Chinese localization for {key}: {zh(key)!r}"

    settings_source = (ROOT / "boringNotch/components/Settings/SettingsView.swift").read_text()
    assert 'Text(Brand.localized(text))' in settings_source, "Settings badges must use the localized Brand table"
    for key, value in {"Beta": "测试版", "Coming soon": "即将推出"}.items():
        assert brand("zh-Hans", key) == value

    if len(sys.argv) == 2:
        bundle = Path(sys.argv[1])
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        assert info["CFBundleName"] == "Interesting Notch"
        assert info["CFBundleExecutable"] == "Interesting Notch"
        for locale in ("en", "zh-Hans"):
            path = bundle / f"Contents/Resources/{locale}.lproj/Brand.strings"
            assert path.exists(), f"Brand strings were not packaged for {locale}"
            result = subprocess.run(["plutil", "-extract", "Interesting Notch", "raw", str(path)], capture_output=True, text=True)
            assert result.returncode == 0 and result.stdout.strip(), f"Brand strings are unreadable for {locale}"

    print("Brand and Simplified Chinese localization checks passed")


if __name__ == "__main__":
    main()
