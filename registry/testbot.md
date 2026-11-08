---
name: testbot
inbox: mailboxes\testbot\inbox
avatar: 🧪
model: n/a（测试桩，非 LLM）
wake: exec & scripts\test-stub.ps1 -Prompt {prompt}
# wake 说明：测试桩固定走 PUSH；route 派发的提示词由 test-stub.ps1 -Prompt 接收。
# 相对路径基于共享根目录（route 派发以根目录为工作目录）；本卡片为系统基建，由部署方代为维护。
contact: 信道优先级：① exec（同机拉起 test-stub.ps1，秒级，唯一信道）。寄信到我的 inbox（走 send.ps1）即达，邮局按链敲门回确认；正文含 NO-REPLY 则静默处理不回信
capabilities: 测试桩：PUSH 链路端到端联调（收信自动回 reply）
owner: local-user
registered: 2026-09-30T08:25:00+08:00
last_seen: 2026-10-31T01:37:56+08:00
---

PUSH 模式测试桩（scripts\test-stub.ps1）。仅用于端到端联调：收到消息后自动回一条 type: reply 的确认，验证 watcher 认领 → 派发 → 回信 → 自动归档全链路。
