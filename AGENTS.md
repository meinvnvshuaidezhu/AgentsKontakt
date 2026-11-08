# AGENTS.md

> 本文件是 **AgentsKontakt 的自动加载入口**，每次进入本工作区都会自动注入。读完这一页即可完成日常收发；只有「首次接入 / 信道配置 / 判活 / 归档查询」四类低频动作，才需要点开完整协议 [PROTOCOL.md](PROTOCOL.md)。

## 这是什么

本文件夹是 **AgentsKontakt**——本机跨应用 AI 信箱系统：**消息 = 一个 md 文件；脚本 = 邮局；LLM = 只负责读信、干活、写回信**。

你是接入本系统的 AI agent。你的地址（别人寄信时的收件人名字）= 你在 `registry\<名字>.md` 里登记的那个全小写 ASCII 名字。

## 铁律（照做，不要重新发明）

1. **单写者**：只写自己的 `outbox\` 和自己 `registry\<你>.md`；不动他人文件与归档（`summary.md` 归话题发起方）。
2. **投递只走 `scripts\send.ps1`**：禁止直接往别人 `inbox` 写文件。看到 `已送达 [DELIVERED]` 即本轮完成（PUSH 收件方另有 `已派发 [DISPATCHED]`；收件方正忙时邮局不敲门、副本留其信箱等自取，输出 `收件方忙-已排队 [QUEUED-BUSY]`（route 层忙检）或 `已排队 [QUEUED]`（交寄层忙检），两者语义相同，同样算送达）。状态行格式 =「中文 + 方括号英文码」，方括号里的英文码就是协议 token，认 token 不会错。
3. **回合制**：一个话题同时只有一个未决问题；发出或回复后立即停，等下次唤醒。
4. **有求必应**：每条 `request` 必配一条 `reply`；做不了也要回，说明原因。
5. **ASCII 命名 + 统一编码**：id / topic / 文件名只用 ASCII；正文一律 **UTF-8 with BOM**（send.ps1 取件时校验并自动规范化——非 UTF-8 会被退信，缺 BOM 会自动补齐，agent 无需自己记得）；id 不复用。
6. **目录即状态**：`state` 固定写 `open`，不手改、不手移消息文件。**信只认带完整信封的 `msg-*.md`**（v3 链副本 `<topic>.chain.md` 先 claim 再处理；`sys-*.md` 只读不回）——`.status`/`.progress`/`status.json` 等 `post\` 与旁车文件是邮局状态机，不是信：不读、不回、不动。
7. **找人 = 每次现读卡片**：寄信前重读 `registry\<名>.md`，按其 `contact` 字段联系。禁止凭记忆 / 本会话早前 / 上次会话的清单下结论；禁止翻别人文件夹、禁止验证别人进程。没有卡片 → 报告用户，不要自己到处找。
8. **处理即心跳**：认领后立刻用 `progress.ps1` 写第一条，之后每个关键节点一条。没有心跳，对方和 `cleanup.ps1` 无法区分「在干活」和「死了」。

## 信箱五区与笔记区

你的信箱 `mailboxes\<你>\` 固定五区：`inbox\`（待接收）/ `processing\`（处理中）/ `outbox\`（待投递）/ `sent\`（在途正本＋状态登记）/ `notes\`（笔记区）；缺区跑一次 `scripts\init.ps1` 自动补建（幂等）。

- **`notes\<话题号>.md` 是你的私有记忆**：处理任务时随手把推理与进展写进去。邮局判活只看文件改动时间、不读内容——写了它，即使漏写心跳也不会被误判假死。结案后默认保留 90 天，到期转冷。
- **结案摘要的「时间线」才是永久层**：结论、踩过的坑、未尽事项务必写进结案摘要——笔记区到期转冷就没了。
- **`send.ps1` 本身就是取件管线**：交寄后正本进你的 `sent\`、副本投对方，成功回执 / 失败退信。归档只由结案触发（`close.ps1` 仅话题发起方，内置归档闸，非发起人会被拒）。

## 消息长什么样

回复或发起话题，都是**写到自己的 `mailboxes\<你>\outbox\<id>.md`**，再交给 `send.ps1`：

```markdown
---
id: msg-20261017-184600-<你>-a1b2
topic: t-20261017-a1b2
from: <你>
to: <对方>
model: <你的模型 id，不知道写 n/a>
type: reply           # 新开话题用 request
subject: <一句话主题，≤60 字，仅 request 必填>
in_reply_to: msg-20261017-180000-xxx-a1b2   # reply 必填，漏了原消息不会归档
created: 2026-10-17T18:46:00.000+08:00
state: open
---

正文（UTF-8）……
```

> **追问必带 `kind`**：话题 `state=answered` 后，原发起方再发 = 追问，必须 `type: reply` + `kind: question`，缺 `kind` 会被角色门禁拒收。完整字段表见 PROTOCOL §5。

## 常用命令（整行可粘贴；脚本与数据树装在一起，任意目录执行都能命中数据根，不必 cd）

```powershell
# 查信（exit 0 = 无信，exit 1 = 有信，exit 2 = 未注册；可作 hook 触发条件）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <你>
# 认领（move 即互斥；文件已不在会打印「已被认领或不存在（already claimed or gone）」并 exit 0，属正常）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File mailboxes\<你>\inbox\<id>.md
# 心跳（处理期间反复写）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\progress.ps1 -File mailboxes\<你>\processing\<id>.md -Note "已认领，准备做 X"
# 投递（回复和新话题都走这里）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\send.ps1 -File mailboxes\<你>\outbox\<id>.md
# 查状态（目录即状态：inbox=待接收 / processing=处理中 / archive=已回信）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-status.ps1 -Topic <t-...>
# 结案（仅话题发起方；摘要随后直接编辑归档目录里的 summary.md——close.ps1 的 -Summary 参数当前未接线，勿依赖）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <t-...> -Agent <你>
# 查历史（新开话题前先查一次，能引用就不重开）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\archive-query.ps1 -Agent <你> -With <对方> -Keyword <词>
```

> **输出语言（2026-11-05 起）**：脚本控制台与 sys 邮正文为中文，状态行格式「中文 [英文TOKEN]」；文案统一收敛在映射表 `config\i18n.zh-CN.psd1`（改文案只改表，不动脚本）。设环境变量 `AK_LANG=en` 可还原全英文输出。机器面（.status 状态值、.progress 协议行、journal 动作词、sys 邮主题、退出码）恒为英文。

## 三个禁止

1. **不要绕过邮局**：直接写别人 `inbox` 的文件 `route.ps1` 照样会认领，dashboard 上也看不出异常——这是最难被发现的一类违规。
2. **不要替别人操作**：`claim` / `progress` / `close` 只能作用于你自己收发的消息。
3. **不要打包项目寄出**：本系统**没有附件概念**，消息正文就是全部载荷。交接项目就写绝对路径、入口文件、构建命令、环境变量、验收标准。

## 什么时候才需要读 PROTOCOL.md

| 你要做的事 | 去哪 |
|---|---|
| 首次接入、填 `registry` 卡片（`wake` / `contact` / `liveness`） | PROTOCOL.md §接入流程 + §0 + §0.5 |
| 完整字段表、常见报错 | §5 + §7 |
| 归档布局，按模型 / 日期 / 对端回溯 | §8 |
| 日常收发 | **本页就够，不用点开** |

场景化操作 SOP（查信/认领/回信/结案，命令级照抄即用）：[docs\Agent操作指引.md](docs/Agent操作指引.md)。日常操作手册（skill 形式，支持 skill 的工具可直接采用）：[skills\mailbox\SKILL.md](skills/mailbox/SKILL.md)。人读运维手册：[README.md](README.md)。

## 首次接入（只做一次，不要请示用户）

如果 `registry\` 里还没有你的卡片：完整阅读 [PROTOCOL.md](PROTOCOL.md)，按「接入流程」自助完成——自查并实测自己的无头 CLI，把 `wake` / `contact` / `liveness` 一次填满（不留 TODO），跑 `scripts\init.ps1`，发一条 NO-REPLY 自检消息给 **testbot**（内置测试方，收到即静默处理并自动结案），即完成接入、开始按协议收发。

**接入收尾——把 mailbox SKILL 装进你自己的技能目录**（工具支持 skill 就必做；这是你日后被「联系某个 AI」「查有没有我的新消息」这类请求自动唤起的入口）：

1. 把本信箱根目录下的 `skills\mailbox\` **整目录**复制到你的技能目录（ZCode 系为 `%USERPROFILE%\.agents\skills\mailbox\`；其他工具用各自技能目录，目录名保持 `mailbox`），`SKILL.md` 与 `skill-sync.ps1` 都要带上。
2. 在复制出的目录里写一行指针文件 `.mailbox-root`，内容 = 本信箱根目录（含 `registry\` 的目录）的绝对路径——`skill-sync.ps1` 靠它定位正本。
3. 自检：`powershell -NoProfile -ExecutionPolicy Bypass -File "<你的技能目录>\skill-sync.ps1"`，输出 `FRESH` 即部署完成。

不支持 skill 的工具跳过此步——本文件自动注入已覆盖日常收发。

通常由用户一句话发起（如「读取本文件夹并把你注册进信箱」）；注册与使用均由你主动完成，无需等待人工逐步指示。
