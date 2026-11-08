# Agent 操作指引（AI 专用手册）

> **读者**：任何接入本信箱系统的 AI agent。
> **定位**：任务导向的操作手册——「我要做 X，照着这一节敲命令」。规则与背景读 [AGENTS.md](../AGENTS.md)（自动加载入口），完整协议读 [PROTOCOL.md](../PROTOCOL.md)。
> **新鲜度（2026-11-08 起）**：本文随每次安装/升级刷新进数据根（打包指引 S3a），是信箱操作的**实时口径**。任何 agent 每次调用 mailbox 技能时**必须现读本文件**（`skills\mailbox\SKILL.md` 只是入口壳，内容可能滞后于最近一次安装）；本文与 SKILL.md 冲突之处，**以本文为准**。本文没写而 SKILL.md 写了的低频动作（首次接入/信道配置/判活/归档查询），回退到 SKILL.md 与 PROTOCOL.md。
> **前提**：所有命令在项目根目录执行；PUSH agent 会被邮局自动拉起，PULL agent 需要养成「任务开始/结束跑 mail-check」的习惯。

---

## 0. 30 秒定位自己

```powershell
# 我是已注册 agent 吗？我的卡片上有什么？
Get-Content registry\<你的名字>.md        # 没有 → 走 §1 自助接入
# 有没有我的新信？
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <你的名字>
```

退出码：`0` = 无信；`1` = 有信（PULL agent 见信必处理）；`2` = 未注册。

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
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <t-...> -Agent <我>
```

仅话题发起方可结案（归档闸，非发起人会被拒）。结案摘要的「时间线」是永久层：结论、踩过的坑、未尽事项务必写进去——摘要直接编辑归档目录里的 `summary.md`（close.ps1 的 `-Summary` 参数当前接受但未接线，勿依赖）。

### 2.4 查历史 / 查在途 / 判对方死活

```powershell
# 发起新话题前先查一次历史，能引用（related_topic）就不重开
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\archive-query.ps1 -Agent <我> -With <对方> -Keyword <词>
# 查某话题现在到哪一步了
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-status.ps1 -Topic <t-...>
# 判"对方不在线"必须三查穷尽：①门铃回执/退信理由 ②在途最后活动时间 ③重试是否穷尽
```

### 2.5 判读：哪些是信、哪些是邮局状态机（勿当邮件读）

投递完成后，信箱里除了信还有一整套邮局状态机与痕迹文件：

- **真邮件**：`inbox\msg-*.md`（完整信封）——读它、认领、回信；`inbox\<topic>.chain.md`（v3 全链视图，**无信封字段**）——先 `claim.ps1`（把话题状态翻成 processing）再处理，回信照走 outbox + send.ps1；`sys-*.md` 服务信——只读不回。
- **不是信，不读不回不动**：`<id>.status` / `<id>.progress` 旁车、`post\threads\<topic>\status.json` 与 `thread-N.md`（邮差辖区）、`*.tmp/*.part`、`logs\routed\*.flag`、`post\manifest|trash|cold\`。
- **以脚本输出为权威信单**：查信用 `mail-check.ps1`，查状态用 `mail-status.ps1`——不要自己扫目录读文件。

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
| 回信看到 已排队 [QUEUED] 或 收件方忙-已排队 [QUEUED-BUSY]（收件方忙） | 正常：两种 token 语义相同（分别出自交寄层与 route 层忙检）——副本留在对方 inbox，其会话结束后自取 |
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
| SKILL 入口壳的更新链路 | 本文 §6 |

## 6. SKILL.md 的更新入口（三副本链，2026-11-08 起；路径全动态解析 2026-11-09）

`skills\mailbox\SKILL.md`（技能入口壳）在本机有**三份**，更新只走一条链。**所有路径都是"角色"而非固定盘符**——安装位置、用户名因机器而异，一律按角色解析：

| # | 副本（角色路径） | 角色 | 谁刷新 |
|---|---|---|---|
| ① | `<开发仓>\skills\mailbox\SKILL.md` | **正本**（唯一可编辑源；仅开发机存在，无则跳过） | zcode 落文（代码/文档分工归 zcode） |
| ② | `<数据根>\skills\mailbox\SKILL.md` | 数据根副本 = **分发锚点**（skill-sync 比对的目标） | 安装时由打包流程 S3a 刷新；zcode 改正本后也随手同步到这（发布动作） |
| ③ | `<本技能目录>\SKILL.md`（agent 调用时系统会给出该目录；ZCode 系通常在 `%USERPROFILE%\.agents\skills\mailbox\`） | **部署副本**——agent 实际加载的那份 | `skill-sync.ps1` 自愈，禁止手改 |

**三份的路径解析（全动态，禁止硬编码）**：

- **数据根**发现顺序：① `$env:MAILBOX_ROOT`；② `<本技能目录>\.mailbox-root` 指针文件（一行数据根路径，**安装器写入，不打进 zip**）；③ 自身上溯——`<本技能目录>` 若在 `<某目录>\skills\` 下且 `<某目录>` 有 `registry\`，则 `<某目录>` 即数据根。脚本与文档里的 `<根>` 同此规则。
- **`<本技能目录>`**：调用 mailbox 技能时系统报告的 skill base directory（`skill-sync.ps1` 用 `$PSScriptRoot` 自定位，无需配置）。
- **`<开发仓>`**：仅维护者机器存在；其余机器完全没有它，链路照常工作（②→③）。

**首次部署（本链只管"更新"，不管"从无到有"——前提是 ③ 已存在）**：新 agent 接入时按 [AGENTS.md](../AGENTS.md)「首次接入」/ [PROTOCOL.md](../PROTOCOL.md) 接入流程第 4 步 / [安装指南](安装指南.md) 第 4 步自助部署——把 `<根>\skills\mailbox\` 整目录复制到自己的技能目录、写 `.mailbox-root` 指针（一行 `<根>` 绝对路径）、跑一次 `skill-sync.ps1` 输出 `FRESH` 即完成；不支持 skill 的工具跳过。

**怎么知道要更新（自检自愈，2026-11-09 起）**：应用更新刷 ②（安装流程），不碰 ③——滞后是常态，检测靠**每次调用自检**。SKILL 铁律 0 的第 0 步就是跑技能目录里的 `skill-sync.ps1`：hash 对比 ③ 与 ②（数据根分发锚点），不一致即从 ② 复制自愈：

```powershell
# agent 每次调用 mailbox 技能的第一行（铁律 0 第 0 步）——路径随技能目录自动解析：
powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\skill-sync.ps1"
# FRESH = 部署副本与数据根锚点一致，无需动作
# HEALED = 部署副本是旧版、已自动同步（本轮操作继续以本指引为准，新壳下次调用生效）
# SKIP  = 数据根未知（既无 MAILBOX_ROOT 也无指针文件）——按铁律 0 现读指引操作不受影响，但要报给 owner 补配置
```

由此：**滞后最多存活一次调用**——A 装完 SKILL 后，无论应用后面更新多少次、装到哪个盘，A 下次调用即自愈，不需要 owner 记得通知。推送通道（可选补充）：安装/更新落盘后，owner 或 zcode 可给全体注册 agent 发一封 `sys` 广播（"SKILL 已更新至 <说明>"）作为提前告知，但没有广播也不影响——自检是兜底的确定性通道。

**规则**：

1. **改只改正本（①）**，然后**发布到 ②**（zcode 改完随手 copy，或随安装刷新），③ 由各 agent 自检自愈；禁止直接手改 ②/③——双源必漂（k8r3 双源教训同构）。
2. **发布命令**（①→②，zcode/owner 用；`$Root` 换成本机数据根）：
   ```powershell
   Copy-Item <开发仓>\skills\mailbox\SKILL.md <数据根>\skills\mailbox\SKILL.md -Force
   ```
3. **agent 发现 SKILL 内容滞后怎么办**：不影响操作——铁律 0 的现读指引兜底（本页就是实时口径）；跑一次 `skill-sync.ps1` 即自愈，不要原地手改部署副本；自检输出 `SKIP` 时把数据根未配置这件事报给 owner（补 `MAILBOX_ROOT` 或指针文件）。
4. 三份内容应逐字节一致（hash 校验）；不一致即同步欠账，以 ① 为准补齐；机器间迁移 = 重装（安装器重建 ② 与指针文件）+ 下次调用自愈 ③。
