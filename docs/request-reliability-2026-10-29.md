# 2026-10-29 · 真实选择题未出现水滴

## 现场与原因

用户反馈真实 `request_user_input_async` 选择题没有触发水滴。现场桥接 `/state` 为 `connected: true`、空任务列表，而当前 Codex 对话仍在运行。只读 IPC 诊断重新关注该对话后，现有桥接立即恢复任务状态；真实问题的 ID、标题和选项均符合投影支持的结构。

桥接把 `thread-stream-following-status-requested` 与普通 `thread-stream-following-changed` 共用“仅首次发现才订阅”的去重判断。客户端重新建立 owner 状态后会询问现有关注者，但桥接已缓存该会话，因此没有回答；连接仍健康，任务快照却不能恢复。客户端实现对已关注会话仍会回答状态询问，owner 收到重复 `following: true` 后会重新提供快照。

## 最小修复

- 原生 Swift 桥接与保留的 Python 实现均对每次状态询问重申关注。
- 普通 `following-changed` 仍去重，防止广播回声循环。
- 复用原有 IPC 校验及恢复路径；没有增加定时器、轮询频率或动画刷新限制。

## 验证

- 新增 socket 回归：已订阅且尚未收到快照的会话，连续两次 owner 状态询问均收到确认；通过有序 discovery-response 屏障确认普通 following-changed 不产生回声。
- 同一回归在旧二进制失败：`Known subscription ignored owner status request 1`；新原生二进制完整集成套件通过，包含安装失败回滚、断线恢复、版本检查、请求回复、重复防护及隐私投影。
- 原生/Python 投影与可执行程序发现的 230 个用例通过；Python 单元测试通过。新增握手回归在 Python 实现也通过，但原生专用 HTTP 整套测试不能直接用于 Python：错误页格式及 chunked 请求行为存在既有差异，未修改这些无关实现。
- 原生桥接已通过现有安装器安装为 `codex-notch-bridge-331e9bb023e19253`。Release 构建、开发签名通过；按调试约定先退出旧应用再启动，检查仅有一个主应用实例。
- 15:05:38 +08:00，新的真实选择题在 `/state` 中为 `waiting` 且含正确问题 ID。用户随后明确确认：“水滴已出现，卡片能打开且没有重叠”。回答后再次读取，待处理问题列表为空，当前对话继续运行。

原始回归、构建及脱敏现场证据位于 `build/request-reliability/`。本次未重新测量能耗或屏幕呈现帧率；修复通过真实交互验证，但不宣称已覆盖长时间运行及未来客户端协议变更。
