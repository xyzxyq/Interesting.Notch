# Codex 桥接原生化评估与验证（2026-09-20）

> 以下为发布前的开发与验证记录；相关改动纳入 [3.0.10](releases/3.0.10.md)，文中的临时路径和进程状态仅对应当时环境。

## 结论与选择

选择 **Swift 独立桥接进程**：应用本体已经是 Swift/SwiftUI，常驻 Python 是 Codex 状态桥接；构建、签名、测试和安装脚本不是长期运行的耗能源。只迁移常驻桥接，同时减少无效唤醒和重复计算。

| 方案 | 适用性与代价 | 本次选择 |
| --- | --- | --- |
| 保留 Python，改调度和缓存 | 改动最小，但仍依赖 Python 运行环境 | 保留为兼容性基线和回退路径 |
| Swift 原生桥接 | 复用现有 Swift 工具链及 Foundation、Darwin、SQLite3、Security；不引入第三方库 | 采用 |
| Rust / Go 独立桥接 | 可以实现，但增加语言和构建维护面；暂无跨平台需求或证据表明 Swift 无法满足开销要求 | 暂不引入 |
| 把桥接直接并入主应用 | 可省独立进程，但需要重做启动、隔离和通信边界，影响面更大 | 保持原有进程边界 |

这是结合当前代码结构的工程选择，不是语言性能排名。降低无效工作优先于仅替换语法；Apple 的 [Mac 能耗指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html) 同样建议减少定时器和无必要工作。

## 实现范围

- `CodexBridge/` 使用优化编译的 Swift 可执行文件替换常驻 Python；没有包管理器或第三方运行时依赖。
- IPC 阻塞等待数据，截止时间取下一次任务发现（10 秒）或心跳刷新（15 秒），删除原来的每秒超时唤醒。待回答问题只在状态更新时重新提取，HTTP 快照复用结果。
- 保留 `127.0.0.1:19427/state` 与 `/answer` 协议、stream v11、额度读取、鉴权、隐私过滤、远程回答、断线重连和重复提交防护。只有明确空闲能参与任务结束判断，断线和修订号丢失不能当作完成。
- 应用每秒 HTTP 查询和每 60 秒短生命周期额度读取仍保留；没有声称完全消除轮询。正常对话文本、账户信息和回答内容不写日志。
- 安装前验证签名并试运行；内容哈希命名保留旧二进制，备份 LaunchAgent，启动失败恢复此前配置。Python 安装/测试工具和回退源代码继续保留。

## 实测与限制

当前 Debug 应用保持同一进程运行；原 Python 桥接由原生桥接替换。两组均使用 `top -l 31 -s 1`，排除首个累计样本，共 30 个有效样本。

| 桥接进程 | 平均 CPU | 峰值 CPU | top MEM |
| --- | ---: | ---: | ---: |
| Python，已运行约 10 小时 | 0.497% | 4.3% | 26–33 MB |
| Swift，新启动 | 0.160% | 1.6% | 约 10 MB |

原始记录：`/tmp/notch-bridge-python-top.txt`、`/tmp/notch-bridge-swift-top.txt`。`top MEM` 与 `ps RSS` 口径不同，不能混用。这是先后采样的现场观察；进程运行时长、任务事件、缓存和系统负载不同，不能视为严格 A/B 性能结论。未测量整机功耗或电池续航，也不能把桥接层数字套用到整个应用。

原生服务上线后检查了任务连接、运行状态、额度和后续心跳，均有效。Debug 主进程未重启；应用端真实动画观感仍依照前一轮的人工测试范围。

## 验证与复现

```sh
scripts/build-codex-bridge.sh /tmp/notch-native-bridge
python3 scripts/check-native-bridge.py
python3 scripts/check-native-bridge-integration.py /tmp/notch-native-bridge
python3 scripts/codex-notch-bridge-install.py --binary /tmp/notch-native-bridge
```

183 组 Python/Swift 投影行为对照通过。隔离 IPC/HTTP 测试覆盖分片消息、运行/等待/空闲、修订缺口、额度、隐私、鉴权、回答去重、送达不确定、明确拒绝后重试、远程回答、重连和不支持的协议版本。安装器测试模拟预检失败、启动失败回滚、成功安装和环境保留，未加载测试 LaunchAgent 或向真实任务发送回答。

回退命令：`python3 scripts/codex-notch-bridge-install.py --python`。本次为本地优化及试用，没有发布新版本或改动已有 Release 附件。

## 燃料图标问号修复 · 2026-09-26

现场桥接的任务连接正常，但 `fuel` 为 `null`、`allowances` 为空。已安装的 Codex 把内置程序迁至 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`；旧桥接仅查找 `Contents/Resources/codex`，而本机旧路径已不存在。用新路径调用只读 `account/rateLimits/read` 成功，证实是程序发现失败。

Swift 桥接和保留的 Python 实现均兼容 ChatGPT.app／Codex.app 的新旧布局，优先当前嵌套布局；保留显式路径覆盖及 PATH 备用查找，跳过不可执行文件和目录。仍沿用每 60 秒一次的额度查询、150 秒新鲜度上限及重置时间校验；没有增加计时器或刷新频率，没有用过期缓存掩盖读取失败。

`check-native-bridge.py` 共 199 项通过，包含 183 项原投影对照及 16 项路径发现回归检查；`check-native-bridge-integration.py` 和原生构建、严格签名校验通过。新桥接已安装到本机，Preview 无需重启便恢复燃料图标；实际界面显示“Codex · 周剩余 8%”。本次仍为本地修复，未发布。

随后连续观察 70.1 秒、15 个样本，任务连接与额度始终有效，覆盖两份不同刷新时间的额度快照；下一次自动刷新后界面正确更新为周剩余 7%，燃料图标仍正常。原始精简记录位于临时文件 `/private/tmp/notch-fuel-20260926/live-validation.json`。这是现场恢复与刷新验证，不是长期可用性或能耗测试。
