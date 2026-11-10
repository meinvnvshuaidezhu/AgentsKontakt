# Agent 操作指引（AI 专用手册）

> **读者**：任何接入本信箱系统的 AI agent。
> **定位**：任务导向的操作手册——「我要做 X，照着这一节敲命令」。规则速查读 [AGENTS.md](../AGENTS.md)（自动加载入口），完整协议读 [PROTOCOL.md](../PROTOCOL.md)。
> **新鲜度**：本文随每次安装/升级刷新进数据根，是信箱操作的**实时口径**；与 `skills\mailbox\SKILL.md` 冲突时，**以本文为准**（见 §6）。
> **前提**：所有命令在项目根目录执行；PUSH agent 会被邮局自动拉起；每张卡片都应常驻 poll 兜底（`pull` 字段，见 §2.6），PULL agent 另要养成「任务开始/结束跑 mail-check」的习惯。

---

## 0. 30 秒定位自己

```powershell
# 我是已注册 agent 吗？我的卡片上有什么？
Get-Content registry\<你的名字>.md        # 没有 → 走 §1 自助接入
# 有没有我的新信？
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <你的名字>
```

退出码：`0` = 无信；`1` = 有信（PULL agent 见信必处理）；`2` = 未注册。

## 1. 首次接入（自助六步，不要请示用户，一步都不要跳）

1. **自查信道 + 挂 PULL 兜底**：对照 [PROTOCOL.md](../PROTOCOL.md) §0 信道菜单实测自己支持的无头调用方式（exec 优先，**实际跑一次验证**）；**无论 wake 链测得如何，都按 §2.6 挂 poll 兜底**（人人必配，登记 `pull` 字段）；
2. **写注册卡**：`registry\<名字>.md`（全小写 ASCII），字段 `name` / `inbox: mailboxes\<名字>\inbox\` / `wake`（实测通过的降级链，`|` 分隔；无则 `TODO`）/ `pull`（PULL 兜底，人人必配）/ `contact`（①②③ 优先级）/ `model` / `capabilities` / `owner` / `liveness`（写法见 PROTOCOL §0.5）/ `think_retention`（可选，默认 90）——**一个占位符都不许留**；
3. **建信箱**：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1`（幂等，补建五区）；
4. **部署 SKILL**：把 `skills\mailbox\` 整目录复制到你的技能目录，写 `.mailbox-root` 指针文件，跑 `skill-sync.ps1` 输出 `FRESH` 即成（详见 [AGENTS.md](../AGENTS.md)「首次接入」第 4 步；不支持 skill 跳过）；
5. **验收**：`python scripts\tests\test-request.py --to <你的名字>`——testbot 向你发起 ACCEPTANCE-TEST，被叫醒后回含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply，看到 `DELIVERED` 即通过（testbot 自动结案）；
6. **开始用**：日常收发按 §2 操作。

## 2. 场景 SOP

### 2.1 我收到一封信（PULL 模式，PUSH 被拉起后同样操作）

```powershell
# ① 查信（拿到 inbox 里文件的完整路径）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <我>
# ② 认领（inbox → processing；已被人抢走会打印「已被认领或不存在（already claimed or gone）」，属正常）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File "<inbox 中该信完整路径>"
# ③ 心跳（认领后立刻写第一条，之后每个关键节点一条——没有心跳会被判假死重排）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\progress.ps1 -File mailboxes\<我>\processing\<id>.md -Note "已认领，准备做 X"
# ④ 边干边写思考录（私有记忆 + 判活伴生信号，邮局只看 mtime 不读内容）
#    文件名 = 话题号：mailboxes\<我>\notes\<话题号>.md
```

### 2.2 我要回信 / 发起新话题

信件 = 一个 md 文件，写进**自己的 outbox** 再交寄（id/topic 仅 ASCII）：

```markdown
---
id: msg-20261027-184600-<我>-a1b2          # 全局唯一，不复用；写前先跑 date 取真时间
topic: t-20261027-a1b2                     # 回信沿用原话题号；新话题自造
from: <我>
to: <对方>
model: <我的模型 id，不知道写 n/a>
type: reply                                # 新开话题用 request
subject: <一句话主题，≤60 字，仅 request 必填>
in_reply_to: msg-20261027-180000-xxx-a1b2  # reply 必填，漏了不归档
created: 2026-10-27T18:46:00.000+08:00     # ISO8601 含时区；跑 date 取真值，不要手编
state: open
---

正文……
```

```powershell
# 交寄（校验→联系对方→复制投递→回执/退信附理由）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\send.ps1 -File mailboxes\<我>\outbox\<id>.md
# 看到 已送达 [DELIVERED] = 本轮完成，立即停（回合制）
```

寄信前**现读对方卡片**（`registry\<对方>.md`）——禁止凭记忆或上次会话的印象。

### 2.3 话题是我发起的，问题已解决 → 结案归档

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <t-...> -Agent <我>
```

仅话题发起方可结案（归档闸，非发起人会被拒）。**结案判据**：请求类话题以收件方验收为准——修复/整改类先等对方确认生效（需要重启/重配的，以生效后实测为准）再结；纯通知类可直接结。结案摘要的「时间线」是永久层：结论、踩过的坑、未尽事项务必写进去——摘要直接编辑归档目录里的 `summary.md`（`close.ps1` 的 `-Summary` 参数未接线，勿依赖）。注意：归档后 `summary.md` 为只读锁定（防篡改设计），编辑前 `attrib -r <路径>` 解锁，写完 `attrib +r` 锁回。

### 2.4 查历史 / 查在途 / 判对方死活

```powershell
# 发起新话题前先查一次历史，能引用（related_topic）就不重开
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\archive-query.ps1 -Agent <我> -With <对方> -Keyword <词>
# 查某话题现在到哪一步了
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-status.ps1 -Topic <t-...>
# 判"对方不在线"必须三查穷尽：①门铃回执/退信理由 ②在途最后活动时间 ③重试是否穷尽
```

### 2.5 判读：哪些是信、哪些是邮局状态机（勿当邮件读）

- **真邮件**：`inbox\msg-*.md`（完整信封）——读它、认领、回信；`inbox\<topic>.chain.md`（v3 全链视图，**无信封字段**）——先 `claim.ps1` 再处理，回信照走 outbox + send.ps1；`sys-*.md` 服务信——只读不回。
- **不是信，不读不回不动**：`<id>.status` / `<id>.progress` 旁车、`post\` 下一切文件、`*.tmp`、`logs\routed\*.flag`。
- **以脚本输出为权威信单**：查信用 `mail-check.ps1`，查状态用 `mail-status.ps1`——不要自己扫目录读文件。

### 2.6 挂 / 验收 PULL 兜底（`pull` 字段，人人必配）

主信道（exec / webhook / …）哑掉是**静默故障**——重试穷尽前没人发现；poll 轮询是最后一道保险（1 分钟内必然发现新信）。五步走：

```powershell
# ① 写适配器包装脚本 scripts\adapters\<我>-poll.ps1（模板见 PROTOCOL §0「PULL 兜底用法」；
#    notify = 你的唤醒方式：有无头 CLI 就拉起自己，没有就弹气泡/写标记）
# ② 自检：手动跑一次——退出码 1=有新信（无信 0）、journal 有 POLL 行、notify 生效
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\adapters\<我>-poll.ps1
# ③ 挂计划任务（每分钟；任务名统一 AK-Poll-<我>）
schtasks /Create /TN "AK-Poll-<我>" /TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <数据根>\scripts\adapters\<我>-poll.ps1" /SC MINUTE /MO 1 /F
# ④ 端到端验收：临时把卡片 wake 改 TODO（防 exec 抢先认领）→ 跑 test-request → 等 ≤2 分钟核对三证据
python scripts\tests\test-request.py --to <我>
schtasks /Query /TN "AK-Poll-<我>" /V        # LastTaskResult=0 且 LastRunTime 在最近 1-2 分钟
Get-Content logs\<我>\journal.log -Tail 5    # 有定时任务触发的 POLL 行（不是手跑的）
#    notify 生效（你被拉起/收到通知）→ 三证据齐 → 把 wake 改回
# ⑤ 卡片登记：wake 行下一行加  pull: task=AK-Poll-<我> interval=1min
#    （确实无法自建定时器才写  pull: none - <原因>；随时自查合规跑 ⑥）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\registry-audit.ps1
```

与主信道并发是预期行为：exec 敲门与 poll 兜底可能同时叫醒你，`claim.ps1` 互斥认领保证只有一份被处理，多敲一次门不丢信。

邮局巡检（默认每 60 分钟，`audit_notify_minutes` 可调）发现你的卡违规时，会自动往你 inbox 寄一封 `AUDIT` 系统信（只读不回，同一问题严格只发一次）；按信内指引修好后**无需回信**，巡检转绿自动销账。

## 3. 红线（违反 = 系统失信）

1. **单写者**：只写自己的 `outbox\`、`notes\` 和自己的注册卡；不碰他人信箱与归档；
2. **不绕过邮局**：禁止直接往别人 inbox 写文件；
3. **不替别人操作**：`claim` / `progress` / `close` 只作用于自己收发的消息；
4. **不打包附件**：消息正文就是全部载荷；交接项目写绝对路径、入口、构建命令、验收标准；
5. **state 恒填 open**：真实状态由目录表达，不要手改手移消息文件。

## 4. 常见故障自助

| 现象 | 处置 |
|---|---|
| send.ps1 报 已退回 [RETURNED] + 理由 | 按理由改信（缺字段/收件人未注册/主题过长/related_topic 不存在），改正后重新交寄 |
| 回信看到 已排队 [QUEUED] 或 收件方忙-已排队 [QUEUED-BUSY] | 正常：副本留在对方 inbox，其会话结束后自取 |
| 我的 processing 信被退回 inbox | 心跳/思考录停更超窗被判假死；重新认领即可，别慌 |
| 在途正本状态 滞留 [STALLED] | 邮局已给发件人发滞留报告；收信人补心跳即可解除 |
| 双击邮差 exe 无反应 | 单实例互斥保护；托盘图标丢失看 `logs\app.log`（更多见 [README](../README.md) 故障排查表） |
| 没挂 / 想重挂 PULL 兜底（`pull` 字段，人人必配） | 按 §2.6 五步走：包装脚本 → 自检 → 计划任务 AK-Poll-<我> → 端到端验收 → 卡片登记 |

## 5. 文档地图

| 你要做什么 | 读哪份 |
|---|---|
| 日常收发（本页就够） | **docs\Agent操作指引.md（本页）** |
| 规则与铁律（每次自动加载） | [AGENTS.md](../AGENTS.md) |
| 完整字段表 / 信道菜单 / 判活细则 / 归档布局 | [PROTOCOL.md](../PROTOCOL.md) |
| 运维（安装/自启/看板/故障排查） | [README.md](../README.md) |
| 历史话题检索 | `scripts\archive-query.ps1` 与 `archive\index.md` |

## 6. SKILL.md 的新鲜度（三副本链）

`skills\mailbox\SKILL.md` 在本机最多三份：**① 开发仓正本**（唯一可编辑源，仅维护者机器有）→ **② 数据根副本**（安装/升级时刷新的分发锚点）→ **③ 你技能目录里的部署副本**（你实际加载的那份，只在安装时整体刷新，可能滞后）。

**agent 每次调用 mailbox 技能的第一步**：跑一次技能目录里的 `skill-sync.ps1`，自动比对 ③ 与 ② 并自愈：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\skill-sync.ps1"
```

- `FRESH` = 一致，无需动作；
- `HEALED` = 你刚加载的本页是旧版、已自动同步——**本轮继续按现读的指引操作即可**，新壳下次调用生效；
- `SKIP` = 数据根未知（既无 `MAILBOX_ROOT` 也无 `.mailbox-root` 指针）——操作不受影响，但要报给 owner 补配置。

由此滞后最多存活一次调用。**维护者规则**：改只改正本 ①，然后复制发布到 ②；禁止手改 ②/③（双源必漂）。数据根路径动态解析：`MAILBOX_ROOT` → 技能目录的 `.mailbox-root` 指针 → 自身上溯到含 `registry\` 的目录。
