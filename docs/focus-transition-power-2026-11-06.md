# 专注开关动画与整机实测 · 2026-11-06

本轮已安装到本机 `~/Applications/InterestingNotch Release.app`。未发布版本，未替换 `/Applications` 正式应用。

## 开关动画

- 开启：0.42 秒缓出，二维聚焦图标与计时轻微聚拢并淡入，歌词投影同步渐显。
- 关闭：0.28 秒轻微收拢并淡出，随后释放投影窗口；普通音乐内容同步恢复。
- 减少动态效果：0.12 秒淡变，不做位移和缩放。
- 快速反向切换复用当前投影；用 generation 检查阻止过期淡出回调删除重新开启的窗口。锁屏、挂起及隐私隐藏仍立即清理。
- 播放与暂停共用 FocusIdleView，避免仅切换播放状态时重建聚焦图标。

## 本机最终构建实测

Apple M5，接通电源、未充电。Apple Music 静音保持原设定，爱奇艺按用户要求暂停。未更改系统亮度、供电或省电设置。每轮稳定 15 秒后采集 45 个约 1 秒样本，采样期间不构建、不打开预览、不操作界面。

| 专注状态 | 应用主进程平均 CPU | 整机功耗均值 | 功耗中位数 | 功耗最小–最大 |
| --- | ---: | ---: | ---: | ---: |
| 有歌词，最好的安排 | 6.60% | 13.20 W | 13.15 W | 12.65–14.50 W |
| 无歌词，River Flows In You | 0.36% | 12.99 W | 12.86 W | 12.42–14.39 W |
| 暂停 | 0.41% | 11.22 W | 11.03 W | 10.61–12.97 W |

CPU 的 100% 表示占满一个逻辑核心，表中是应用主进程，不包含 Music、WindowServer 等进程。整机功耗包含这些进程、显示屏及其他硬件，不能全部归因于本应用。最终三轮全机 CPU 忙碌占比分别为 17.80%、16.90%、12.88%（归一化到全部核心）。

整机读数来自 AppleSMC `PSTR`（Stats 的传感器表将其定义为 System Total），不是插座功率计，也不是 powermetrics 的 CPU/GPU/ANE 合计。先验证了 PSTR 逐秒更新；AppleSmartBattery `SystemPowerIn` 虽与电压×电流量级一致，但连续几十秒返回缓存值，因此只保留作诊断，不用于正式功耗结论。`sudo -n powermetrics` 需要管理员密码，未提升权限。

参考实现：[Stats SMC reader](https://github.com/exelban/stats/blob/master/SMC/smc.swift)、[传感器映射](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)。本轮仅在测量工具中调用 `getValue("PSTR")`，未写入 SMC，未安装服务；该参考代码不进入应用。保存的 `smc.swift` SHA-256：`a4a614937cbff46723990c1b1e3e8e3ccc810fd1f690d7f445c361f167de9692`。

## 根据调用栈实施的优化

调用栈发现同一句歌词仍重复进入 NSString/CoreText 测宽。本轮在现有组件中增加最多 32 条文字宽度缓存；同时波纹直接使用已知尺寸，移除每帧的 `visualEffect` 几何查询。没有降低动画帧率、减少粒子数量或改变波纹速度。

同一首《最好的安排》从开头播放，稳定 15 秒、测量 45 秒的对照：

| 构建 | 应用 CPU 均值 | 整机功耗均值 | Music CPU | 爱奇艺 CPU |
| --- | ---: | ---: | ---: | ---: |
| 本轮优化前 | 9.60% | 13.08 W | 3.82% | 4.31% |
| 本轮优化后 | 6.60% | 13.20 W | 3.72% | 4.10% |

这一次对应片段的应用 CPU 下降约 31.2%；整机功耗没有下降，不宣称已经改善续航。歌词长度、渲染缓存和后台负载都会影响结果；短时、非隔离、单次有效配对不能建立普遍的百分比收益。

初步两轮用于定位开销：有歌词 CPU 4.74% / 9.51%，无歌词 0.43% / 0.39%，暂停 0.38% / 0.93%。它们不是完全对齐的歌词片段，不用于计算优化百分比。无歌词首轮整机峰值 32.40 W，说明背景活动会显著污染整机对比。

明确排除：含视频播放的诊断轮、仅用于传感器校准的轮次，以及 `lyrics-paired-after-2`（应用菜单仍展开，可能改变动画调度）。后者测得 4.34% CPU，不能当作有效优化结果。

## 验证与复现

- Release 编译成功，稳定开发签名通过，仅一个应用主进程。隔离构建未包含工作区已有的 VolumeManager、CodexBridge、拉绳等无关实验。
- GPU 渲染检查通过：单个透明波峰、三处波纹位置、长歌词完整性、12 个粒子色相区间、消散完成无残留。
- 优化前后 7 张波纹／文字／粒子检查图的 RGBA 各通道逐像素相同。
- 开关生命周期、快速反转、过期完成回调、立即隐私清理、减少动态效果检查通过；测宽检查覆盖中英文、空字符串及 emoji。
- 复用实际聚焦组件和 ContentView 过渡参数的原生预览已检查开／关两端界面；预览窗口已关闭。
- 视觉偏好仍以用户实际键盘切换后的观察为准；自动化生命周期和渲染检查不等于人的动态视觉验收。

源文件：`ContentView.swift`、`ImmersiveLyricsPanel.swift`、`ImmersiveFocus.swift`、`ImmersiveLyricsView.swift`。测试：`scripts/ImmersiveProjectionChecks.swift`。只读采样：`scripts/FocusPowerProbe.swift`。

原始数据与日志在 `build/focus-transition-power-20261106/`：

- `lyrics-paired-before.json`、`lyrics-paired-after.json`：有效片段对照。
- `no-lyrics-final.json`、`paused-final.json`：最终构建另两种状态。
- `summary.json`：全部轮次与明确排除原因；`real-app-sample.txt`：调用栈。
- `final-render/`：最终渲染输出与生命周期日志；`optimized-build.log`：Release 构建记录。

采样工具使用 `proc_pidinfo` 累积 CPU 时间差和 Mach 时间基准，并在每次启动执行 80 ms 忙循环校准；本机约 0.98–1.00 核的校准值通过。不能将 M5 的 Mach tick 误当作纳秒。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -D SMC_PROBE -parse-as-library scripts/FocusPowerProbe.swift \
  build/focus-transition-power-20261106/reference/smc.swift \
  -o build/focus-transition-power-20261106/FocusPowerProbe

# 先通过实际播放器建立并核实状态；PID 需重新查询。
build/focus-transition-power-20261106/FocusPowerProbe \
  label /absolute/path/result.json 45 app=MAIN_PID music=MUSIC_PID video=VIDEO_PID
```

不带 `SMC_PROBE` 编译时只有缓存电源字段，不能将它当作正式实时功耗。测量脚本不修改播放、系统亮度、充电策略或应用设置。
