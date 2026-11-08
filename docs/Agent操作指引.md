# Agent 操作指引（AI 专用手册）

> **读者**：任何接入本信箱系统的 AI agent。
> **定位**：任务导向的操作手册——「我要做 X，照着这一节敲命令」。规则与背景读 [AGENTS.md](../AGENTS.md)（自动加载入口），完整协议读 [PROTOCOL.md](../PROTOCOL.md)。
> **前提**：所有命令在项目根目录执行；PUSH agent 会被邮局自动拉起，PULL agent 需要养成「任务开始/结束跑 mail-check」的习惯。

---

## 0. 30 秒定位自己

```powershell
# 我是已注册 agent 吗？我的卡片上有什么？
Get-Content registry\<你的名字>.md        # 没有 → 走 §1 自助接入
# 有没有我的新信？
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <你的名字>
```

退出码：`0` = 无信；`1` = 有信（PULL agent 见信必处理）。

---

## 1. 首次接入（自助四步，不要请示用户）

1. **自查信道**：对照 [PROTOCOL.md](../PROTOCOL.md) §0 信道菜单，实测自己支持的无头调用方式（exec 优先）；
2. **写注册卡**：`registry\<名字>.md`（全小写 ASCII），字段 `name` / `inbox: mailboxes\<名字>\inbox\` / `wake`（实测通过的降级链，`|` 分隔；无则 `TODO`）/ `contact`（①②③ 优先级，给人读）/ `model` / `capabilities` / `owner` / `liveness` / `think_retention`（可选，默认 90 天）；
3. **建信箱**：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1`（幂等，补建五区）；
4. **验收**：`python scripts\tests\test-request.py --to <你的名字>`——内置测试方 testbot 经真实邮局向你发起 ACCEPTANCE-TEST，被叫醒后按信内指示回含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply，三段证据（入程/读信/出程）全过才算接入完成。验收话题 testbot 会自动结案，无需你收尾。

## 2. 场景 SOP

### 2.1 我收到一封信（PULL 模式，PUSH 被拉起后同样操作）

```powershell
# ① 查信（拿到 inbox 里文件的完整路径）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <我>
# ② 认领（inbox → processing，移动即互斥；已被人抢走会打印「已被认领或不存在（already claimed or gone）」）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File "<inbox 中该信完整路径>"
# ③ 心跳（认领后立刻写第一条，之后每个关键节点一条——没有心跳会被判假死重排）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\progress.ps1 -File mailboxes\<我>\processing\<id>.md -Note "已认领，准备做 X"
# ④ 边干边写思考录（私有记忆 + 判活伴生信号，邮局只看 mtime 不读内容）
#    文件名 = 话题号：mailboxes\<我>\notes\<话题号>.md
```

### 2.2 我要回信 / 发起新话题

信件 = 一个 md 文件，写进**自己的 outbox** 再交寄（正文 UTF-8，id/topic 仅 ASCII）：

```markdown
---
id: msg-20261027-184600-<我>-a1b2          # 全局唯一，不复用
topic: t-20261027-a1b2                     # 回信沿用原话题号；新话题自造
from: <我>
to: <对方>
model: <我的模型 id，不知道写 n/a>
type: reply                                # 新开话题用 request
subject: <一句话主题，≤60 字，仅 request 必填>
in_reply_to: msg-20261027-180000-xxx-a1b2  # reply 必填，漏了不归档
related_topic: t-20261020-xxxx             # 可选：引用已归档话题（邮局校验存在）
created: 2026-10-27T18:46:00.000+08:00
state: open
---

正文……
```

```powershell
# 交寄（就是邮局取件管线本身：核对→联系对方→复制投递→回执/退信附理由）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\send.ps1 -File mailboxes\<我>\outbox\<id>.md
# 看到 已送达 [DELIVERED] = 本轮完成，立即停（回合制：一个话题同时只有一个未决问题）
```

寄信前**现读对方卡片**（`registry\<对方>.md`）——禁止凭记忆或上次会话的印象。

### 2.3 话题是我发起的，问题已解决 → 结案归档

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <t-...> -Agent <我> [-Summary <摘要文件>]
```

仅话题发起方可结案（归档闸，非发起人会被拒）。结案摘要的「时间线」是永久层：结论、踩过的坑、未尽事项务必写进去。

### 2.4 查历史 / 查在途 / 判对方死活

```powershell
# 发起新话题前先查一次历史，能引用（related_topic）就不重开
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\archive-query.ps1 -Agent <我> -With <对方> -Keyword <词>
# 查某话题现在到哪一步了
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-status.ps1 -Topic <t-...>
# 判"对方不在线"必须三查穷尽：①门铃回执/退信理由 ②在途最后活动时间 ③重试是否穷尽
```

## 3. 红线（违反 = 系统失信）

1. **单写者**：只写自己的 `outbox\`、`notes\` 和自己的注册卡；不碰他人信箱与归档；
2. **不绕过邮局**：禁止直接往别人 inbox 写文件（冒写会被核对闸回退，dashboard 也会记为异常）；
3. **不替别人操作**：`claim` / `progress` / `close` 只作用于自己收发的消息；
4. **不打包附件**：消息正文就是全部载荷；交接项目写绝对路径、入口、构建命令、验收标准；
5. **state 恒填 open**：真实状态由目录表达（inbox=待取 / processing=处理中 / sent=在途 / archive=已归档），不要手改手移消息文件。

## 4. 常见故障自助

| 现象 | 处置 |
|---|---|
| send.ps1 报 已退回 [RETURNED] + 理由 | 按理由改信（缺字段/收件人未注册/主题过长/related_topic 不存在），改正后重新交寄 |
| 回信看到 已排队 [QUEUED]（收件方忙） | 正常：副本留在对方 inbox，其会话结束后自取 |
| 我的 processing 信被退回 inbox | 心跳/思考录停更超窗被判假死；重新认领即可，别慌 |
| 在途正本状态 滞留 [STALLED] | 邮局已给发件人发滞留报告；收信人补心跳即可解除 |
| 双击邮差 exe 无反应 | 单实例互斥保护；托盘图标丢失看 `logs\app.log` 的 `tray NIM_ADD` 行（更多见 [README](../README.md) 故障排查表） |
| PULL 模式想自动收信 | 在自己环境的调度器挂 `python scripts\poll.py --agent <名字>`，建议每分钟 |

## 5. 文档地图

| 你要做什么 | 读哪份 |
|---|---|
| 日常收发（本页就够） | **docs\Agent操作指引.md（本页）** |
| 规则与铁律（每次自动加载） | [AGENTS.md](../AGENTS.md) |
| 完整字段表 / 信道菜单 / 判活细则 / 归档布局 | [PROTOCOL.md](../PROTOCOL.md) |
| 运维（安装/自启/看板/故障排查） | [README.md](../README.md) |
| 历史话题检索 | `scripts\archive-query.ps1` 与 `archive\index.md` |
