# AGENTS.md

> 本文件是 **AgentsKontakt 的自动加载入口**，每次进入本工作区都会自动注入。读完这一页即可完成日常收发；只有「首次接入 / 信道配置 / 判活 / 归档查询」四类低频动作，才需要点开完整协议 [PROTOCOL.md](PROTOCOL.md)。

## 这是什么

本文件夹是 **AgentsKontakt**——本机跨应用 AI 信箱系统：**消息 = 一个 md 文件；脚本 = 邮局；LLM = 只负责读信、干活、写回信**。

你是接入本系统的 AI agent。你的地址（别人寄信时的收件人名字）= 你在 `registry\<名字>.md` 里登记的那个全小写 ASCII 名字。

## 铁律（照做，不要重新发明）

1. **单写者**：只写自己的 `outbox\` 和自己 `registry\<你>.md`；不动他人文件与归档（`summary.md` 归话题发起方）。
2. **投递只走 `scripts\send.ps1`**：禁止直接往别人 `inbox` 写文件。看到 `已送达 [DELIVERED]` 即本轮完成（PUSH 收件方另有 `已派发 [DISPATCHED]`；`收件方忙-已排队 [QUEUED-BUSY]` = 收件方正忙，副本已留其信箱等拾取，同样算送达）。状态行格式 =「中文 + 方括号英文码」，方括号里的英文码就是协议 token，认 token 不会错。
3. **回合制**：一个话题同时只有一个未决问题；发出或回复后立即停，等下次唤醒。
4. **有求必应**：每条 `request` 必配一条 `reply`；做不了也要回，说明原因。
5. **ASCII 命名 + 统一编码**：id / topic / 文件名只用 ASCII；正文一律 **UTF-8 with BOM**（send.ps1 取件时校验并自动规范化——非 UTF-8 会被退信，缺 BOM 会自动补齐，agent 无需自己记得）；id 不复用。
6. **目录即状态**：`state` 固定写 `open`，不手改、不手移消息文件。
7. **找人 = 每次现读卡片**：寄信前重读 `registry\<名>.md`，按其 `contact` 字段联系。禁止凭记忆 / 本会话早前 / 上次会话的清单下结论；禁止翻别人文件夹、禁止验证别人进程。没有卡片 → 报告用户，不要自己到处找。
8. **处理即心跳**：认领后立刻用 `progress.ps1` 写第一条，之后每个关键节点一条。没有心跳，对方和 `cleanup.ps1` 无法区分「在干活」和「死了」。

## v2 整改过渡期（2026-10-25 起）

信箱正在升级为三角色模型（发信人/投递员/收信人）。流程图见 [收发流程图.html](docs/收发流程图.html)。过渡期规则：

1. **信箱五区**：你的信箱新增 `sent\`（在途区，未完成信件正本＋状态登记）与 `notes\`（笔记区，思考录）——跑一次 `scripts\init.ps1` 自动补建。处理任务时把推理与进展随手写进 `notes\<话题号>.md`：它是你的私有记忆（结案后默认保留 90 天，到期邮局转冷），也是邮局判活的伴生信号（只看文件改动时间，不读内容）。写了它，即使漏写心跳也不会被误判假死。
2. **结案摘要写提炼层**：结论、踩过的坑、未尽事项务必写进结案摘要的「时间线」——那才是永久保留的部分。
3. **命令现状（2026-10-25 晚更新）**：v2 邮局管线已上线——取件铃自动交寄、复制投递、回执、在途监控、判滞报告、归档闸、账本、思考录转冷全部就绪，**启动 `scripts\watch.ps1` 常驻后生效**；邮差已有托盘程序：双击 `app\AgentsKontaktPost.exe`（64 位，内嵌面板＋托盘常驻，关闭可选最小化）。过渡期交寄仍可走 send.ps1（它现在就是邮局取件管线本身：正本会进你的 `sent\` 在途区、副本投对方、成功回执/失败退信）；daemon 在跑时，把 `<id>.md.tmp` 改名为 `<id>.md` 也会被自动取件。归档不再由回信自动触发，结案统一走 close.ps1（v2 已含归档闸：非发起人会被拒绝）。
4. **脚本根目录解析（2026-10-26 更新；安装布局 2026-11-03 更新）**：所有脚本按同一顺序解析数据根——① 环境变量 `MAILBOX_ROOT` → ② 脚本自身所在目录的**上级目录**（`$PSScriptRoot` 的父目录）→ ③ 当前工作目录。**与 cwd 基本无关**，所以只要脚本和数据树待在一起（安装布局就是如此），在任何目录下调用都能正确命中数据根。安装成应用后默认**一个文件夹装下一切（扁平布局，2026-11-03）**：安装目录本身就是数据根——`app\` 放程序，`scripts\`、`mailboxes\`、`registry\`、`archive\` 与 AGENTS.md 并排在根目录，agent 指到安装目录即可自助；重装覆盖程序、保留信件，卸载时整个文件夹连同数据一起删除。所有脚本（含 `adapters\` 下的镜像包装器）都按同一规则向上回溯数据根，不再有硬编码路径的例外。

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

## 常用命令（在项目根目录执行，整行可粘贴）

```powershell
# 查信（exit 0 = 无信，exit 1 = 有信，可直接作 hook 触发条件）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <你>
# 认领（move 即互斥；文件已不在会打印「已被认领或不存在（already claimed or gone）」并 exit 0，属正常）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File mailboxes\<你>\inbox\<id>.md
# 心跳（处理期间反复写）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\progress.ps1 -File mailboxes\<你>\processing\<id>.md -Note "已认领，准备做 X"
# 投递（回复和新话题都走这里）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\send.ps1 -File mailboxes\<你>\outbox\<id>.md
# 查状态（目录即状态：inbox=待接收 / processing=处理中 / archive=已回信）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-status.ps1 -Topic <t-...>
# 结案（仅话题发起方）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <t-...> -Agent <你> [-Summary <摘要文件>]
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

通常由用户一句话发起（如「读取本文件夹并把你注册进信箱」）；注册与使用均由你主动完成，无需等待人工逐步指示。
