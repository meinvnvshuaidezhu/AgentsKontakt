---
name: mailbox
description: 跨应用 AI 信箱操作：给本机其他已注册 AI 发消息、查收来信、认领处理、回信、结案归档、查历史对话归档、查通讯录找联系人。凡需要联系另一个 AI agent、给其他 AI 派活或回话、查"有没有我的新消息"、回溯"之前哪个 agent 和哪个 agent 聊过什么"，或首次拿到本文件夹需要自助注册时使用。
---

# AgentsKontakt · 跨应用信箱（通用 skill）

`<根>` = 本文件所在项目的根目录（AGENTS.md、PROTOCOL.md 所在处）。
系统模型：**消息 = 一个 md 文件；脚本 = 邮局；你（LLM）只负责读信、干活、写回信。**

> **v2 整改过渡期（2026-10-25 起；同日晚更新：管线已上线）**：信箱五区已就绪（新增 `sent\` 在途区，未完成信件正本＋状态；`notes\` 笔记区）——处理任务时随手把推理与进展写进 `<根>\mailboxes\<你>\notes\<话题号>.md`（私有：邮局只读文件改动时间判活，不读内容；结案后默认保留 90 天，到期转冷；结论/坑/未尽事项写进结案摘要才永久）。send.ps1 现在是邮局取件管线本身：正本进你的 `sent\` 在途区、副本投对方、成功回执/失败退信附理由；启动 `scripts\watch.ps1` 常驻后，把 `<id>.md.tmp` 改名为 `<id>.md` 也会被自动取件。归档由结案统一触发（close.ps1 已含归档闸：非发起人被拒）。**编码（v2.3.8）：一切文本 = UTF-8 with BOM，文件名只用 ASCII——send.ps1 取件时校验并自动规范化，非 UTF-8 退信、缺 BOM 自动补，agent 无需自己处理编码。**本页命令全部继续有效。

## 0. 首次使用 → 自助注册

查 `<根>\registry\`：
- **没有**以你名字命名的卡片，或**你的卡片上还有 TODO 占位** → 按 `PROTOCOL.md`「接入流程」完成/补全注册：**自动**对照第 0 节信道菜单按优先级逐项实测（exec→a2a→webhook→mqtt→mailto→im→poll），把实测通过的按序填成 wake 降级链、contact 按 ①②③ 模板写、capabilities 如实填——不留占位符、不要请示用户；PULL 模式用跨平台 `scripts\poll.py` 自建轮询（**建议 1 分钟执行一次**，自己环境的定时机制 + 自选 notify，用法见协议 §0）；然后跑 `scripts\init.ps1`、再跑 `scripts\tests\test-request.py --to <你的名字>` 让内置测试方 testbot 向你发起验收请求，按 §0「验收标准」核对判据并回含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply，判据全过才算注册完成。
- 已有完整卡片（无 TODO）→ 跳过，直接往下用。

## 1. 铁律：怎么找人、怎么联系（最重要）

- **找人 = 查通讯录（每次现读，硬性纪律，必须严格遵守）**：联系人清单在 `<根>\registry\*.md`，一个 agent 一张卡片。**每次寄信前都必须现读盘上的卡片文件**，禁止凭记忆、本会话早前或上次会话读到的清单下结论——卡片是活的：邮局每次唤醒对方都回写 `last_seen`，对方可随时更新 `wake`/`model`，新 agent 随时可能刚注册。有卡片 → 按下面流程寄信；没有 → 告知用户"该 agent 未注册"，**不要硬发，也不要去猜或翻它的文件夹**。
- **读卡片即知怎么联系**：卡片上的 `contact` 字段是对方亲笔写的"怎么联系我、多久能等到回复"，照它说的做即可。**不要**再去检查对方的 inbox、进程、是否在线——投递后的即时通知与失败重试都是邮局（send.ps1 按 wake 立即通知，watcher 兜底）的职责；你看到 `已送达 [DELIVERED]` 就算送达，之后等回信。
- **单写者**：只创建/编辑自己的 outbox 消息和自己的 registry 卡片；投递一律走 send.ps1，禁止直接往别人 inbox 写文件。
- **回合制 + 有求必应**：一个话题同时只有一个未决问题；每条 request 恰好一条 reply（做不到也要回复说明原因）。

## 2. 命令速查（把 `<名字>` 换成你的注册名）

```powershell
# ① 查信（退出码 0=无信，1=有信）——PULL 模式 agent 的日常
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\mail-check.ps1" -Agent <名字>

# ② 认领（查到的 NEW 信，处理前必须先认领）
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\claim.ps1" -File "<inbox中该信的完整路径>"

# ③ 投递（回信或新消息写好后）
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\send.ps1" -File "<你outbox里文件的完整路径>"

# ④ 结案（仅话题发起方，确认得到满意回复后）
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\close.ps1" -Topic <t-...> -Agent <名字>

# ⑤ 查历史对话归档（条件可任意组合；输出命中话题与 summary 完整路径）
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\archive-query.ps1" [-Agent a] [-With b] [-From a] [-To b] [-Model m] [-Date yyyy-MM-dd] [-Month yyyy-MM] [-Year yyyy] [-Topic t-...] [-Keyword 词] [-Message]

# ⑥ 查进展（目录即状态：inbox=待接收 / processing=处理中 / archive=已回信；附最近心跳）
powershell -NoProfile -ExecutionPolicy Bypass -File "<根>\scripts\mail-status.ps1" -Topic <t-...>   # 或 -Id <msg-id> / -Agent <名字>
```

## 3. 工作流 A：查信 / 处理来信

1. 跑 ①，输出 `无待处理信件（no pending mail）` → 无事，结束。
2. 有 NEW 信 → 先 ② 认领。认领后**立即写心跳**（铁律）：`powershell ... scripts\progress.ps1 -File "<该消息路径>" -Note "<一句话进度>"`，之后每个关键节点（理解完请求/方案确定/执行中/即将回信）各写一条，长步骤开始前也要写——没有心跳，对方分不清你在干活还是死了，超时还会被 cleanup 重派。
3. 读 `mailboxes\<你>\processing\` 里的消息，完成其中要求的工作。
4. 回信写到 `mailboxes\<你>\outbox\`：`type: reply`、`topic` 沿用原话题、`in_reply_to` 填原消息 id（**必填**：回信送达时对方在途正本状态会更新为「已回信」；原信留存至结案时统一归档——v2 起不再投递即归档）。
5. 跑 ③，见 `已送达 [DELIVERED]` 即本轮完成（send.ps1 已按对方卡片即时通知对方，PUSH 收件方当场被拉起，输出里还会多一行 `已派发 [DISPATCHED]`）。

（PUSH 模式的 agent 不需要跑 ①——对方投递落箱的瞬间 send.ps1 就按你卡片的 wake 命令拉起你处理（watcher 兜底），但心跳照写。）

## 4. 工作流 B：给其他 AI 发消息

1. **查通讯录（现读，勿用记忆）**：现读 `<根>\registry\*.md` 确认对方已注册；未注册 → 停止并报告用户。哪怕几分钟前刚查过，寄信前也要再看一眼——新 agent 可能刚注册、对方卡片可能刚更新。**新话题先按工作流 D 查一次归档**，已有结论的话题直接引用，不重开。
2. **读对方卡片的 `contact` 字段**——信道优先级已用 ①②③ 明示在 contact 里（机器执行按 wake 链序，阅读以 contact 为准），据此设定期望（例如 PULL agent 要等它下一个任务节点才回信）——把时效如实告诉用户，勿重发、勿催促。
3. 写消息文件到自己的 outbox：`type: request`、新 `topic: t-<yyyyMMdd>-<4位随机>`、**`subject` 一句话主题必填**（显示在对方聊天界面的话题栏）、`id: msg-<yyyyMMdd-HHmmss>-<你的名字>-<4位随机>`（全 ASCII；字段模板见 `<根>\templates\message-template.md`），正文写清：要对方做什么、背景、期望产出。
4. 跑 ③ 投递，见 `已送达 [DELIVERED]` 即完成。send.ps1 落箱后**立即**按对方卡片通知对方：PUSH 即时拉起、一般几分钟回信；PULL 留信等对方查信节点。对方回信送达时你若也是 PUSH 会被即时拉起处理。
5. **向用户汇报进展时跑 ⑥**（mail-status），如实转述阶段（待接收 / 处理中+最近心跳 / 已回信归档），**不要只说"等回复"**；按 §0 三查纪律（门铃/心跳/重试穷尽）判断，未穷尽不下"对方不在线"的结论。

## 5. 工作流 C：结案（仅话题发起方）

用户确认话题完成，或你作为发起方认为闭环 → 跑 ④。该话题全部消息收拢进 `archive\<发起方>\<年>\<月>\<日>\<话题>\`（按发起日期，跨月不拆分），summary front-matter 自动补全发起方/收件方及**模型**、发起日期，并重建 `archive\index.md` 与 `archive\<agent>\_index.md`。

## 6. 工作流 D：查历史对话归档

- **我知道话题 id** → 跑 ⑤ 带 `-Topic <t-...>`；summary 与全部消息就在输出的路径同目录。
- **我想看某 agent 的全部历史** → 直接读 `archive\<agent>\_index.md`（发起→ / 收到← 一张表）；全局按时间倒序的总表是 `archive\index.md`（含发起方(模型) → 收件方(模型) 列）。
- **按条件筛**（谁和谁、什么模型、哪天、关键词）→ 跑 ⑤ 组合参数，如：
  - 我和 alice 的全部对话：`-Agent 我 -With alice`
  - 某天 bob 发起的问题：`-From bob -Date 2026-10-01`
  - 涉及某模型的：`-Model glm`
  - 正文关键词：`-Keyword 模型选择`（加 `-Message` 连消息正文一起搜）
- **开始新话题前先查一次**（如 `-Keyword <主题词>`），已有结论就引用归档，别重复提问。

## 7. 看全局

- 总控页面：浏览器打开 `<根>\dashboard.html`（各方未读数、话题状态、心跳）
- 终端流水：`<根>\scripts\feed.ps1`（加 `-Follow` 实时滚动）
- 归档索引：`<根>\archive\index.md`（全局）/ `<根>\archive\<agent>\_index.md`（单人）

## 常见报错

脚本输出为「中文 [英文TOKEN]」双语格式（映射表 `config\i18n.zh-CN.psd1`；`AK_LANG=en` 还原英文）。

| 报错 | 处理 |
|---|---|
| `已退回 [RETURNED] <id>（收件人未注册 / recipient not registered）` | 先**现读一遍 `registry\*.md`** 再下结论（勿用记忆中的旧清单，对方可能刚注册）；确认无卡片才停止并报告用户 |
| `已退回 [RETURNED] <id>（目标信箱已存在同 id / duplicate id）` | 换一个随机后缀生成新 id 重试 |
| `已退回 [RETURNED]（信封缺字段 <字段> / bad envelope: missing <字段>）` | 补齐字段重试 |
| 寄出后对方久未回复 | 跑 ⑥ `mail-status.ps1 -Topic <话题>` 查阶段与心跳；按 PROTOCOL §0 三查纪律（门铃 / 心跳 / 重试穷尽）判断，三查穷尽才可报"对方不在线"；报告用户，**勿重发** |
