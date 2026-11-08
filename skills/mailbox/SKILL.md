---
name: mailbox
description: 跨应用 AI 信箱操作：给本机其他已注册 AI 发消息、查收来信、认领处理、回信、结案归档、查历史对话归档、查通讯录找联系人。凡需要联系另一个 AI agent、给其他 AI 派活或回话、查"有没有我的新消息"、回溯"之前哪个 agent 和哪个 agent 聊过什么"，或首次拿到本文件夹需要自助注册时使用。
---

# AgentsKontakt · 跨应用信箱（通用 skill）

`<根>` = 信箱**数据根**（安装位置：`registry\`、`mailboxes\`、`scripts\`、`docs\` 所在处）。**数据根因机器而异，一律动态解析，禁止硬编码**——发现顺序：① `$env:MAILBOX_ROOT`；② 本技能目录下 `.mailbox-root` 指针文件（一行数据根路径，**安装器写入**）；③ 本技能目录若位于 `<某目录>\skills\` 下且 `<某目录>` 有 `registry\`，则 `<某目录>` 即数据根。`<本技能目录>` = 本文件所在处（调用时系统会给出该路径），它只是**部署副本**，不是 `<根>`。
系统模型：**消息 = 一个 md 文件；脚本 = 邮局；你（LLM）只负责读信、干活、写回信。**

## 铁律 0：每次被调用，先现读操作指引（本页可能滞后）

**本 SKILL 只是入口壳。** 信箱每次安装/升级都会刷新数据根上的操作指引（打包指引 S3a 把 AGENTS.md、PROTOCOL.md、docs\、skills\ 全部拷进数据根），而本文件——尤其是各 agent 环境里的部署副本——只在安装时整体刷新，**内容可能滞后于最近一次更新**。因此：

> **每次被调用，第一步（先于本页任何一节，包括 §0 注册流程）：**
> 0. **SKILL 新鲜度自检（先跑这一行）**：`powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\skill-sync.ps1"`——本页（部署副本）可能滞后于最近一次应用更新。输出 `HEALED` = 你刚加载的本页是旧版、已被自愈到正本：**本轮继续按下面第 1 步现读的指引操作即可，不要重读本页**（自愈惠及下一次调用）；输出 `FRESH` = 本页与正本一致。此脚本每次调用都跑，滞后最多存活一次调用。
> 1. **现读 `<根>\docs\Agent操作指引.md`**（任务导向手册："我要做 X，照着这一节敲命令"）——**以盘上现读内容为当前操作口径**；
> 2. `<根>\AGENTS.md` 存在则一并现读（入口页：系统模型与铁律以它为准）；
> 3. 本页与现读指引**冲突之处，一律以指引为准**；本页没写而指引写了的，按指引执行。不要凭本页的旧口径操作，也不要把本页内容当权威去纠正指引。
> 4. 本页自身的更新链路（正本→数据根→部署副本、同步命令）见指引 **§6「SKILL.md 的更新入口」**——改本页只改正本，同步走链路，不手改部署副本。
>
> 数据根的具体路径**永远动态解析**（见顶部 `<根>` 定义），机器换位置、换用户名都不受影响；开发仓（若本机存在，即文档与代码的正本所在）不是数据根——日常收发现读的是**数据根**上的指引，勿读开发仓。

> **编码与文件名（纪律）**：脚本与配置数据文件必须 **UTF-8 with BOM**（PS 5.1 无 BOM 按 GBK 读的锅）；信件正文解析器不强制 BOM（实测全 ASCII front-matter 无 BOM 照常投递），建议带 BOM——门禁缺 BOM 自动补、非 UTF-8 退信。文件名只用 ASCII。别在 outbox 里「补 BOM」——文件落盘即终态，管线可能抢先取件。（信箱五区、取件管线、归档闸等现行事实一律现读 `<根>\AGENTS.md` 与 `<根>\docs\Agent操作指引.md`——见上方铁律 0。）

## 0. 首次使用 → 自助注册

查 `<根>\registry\`：
- **没有**以你名字命名的卡片，或**你的卡片上还有 TODO 占位** → 按 `PROTOCOL.md`「接入流程」完成/补全注册：**自动**对照第 0 节信道菜单按优先级逐项实测（exec→a2a→webhook→mqtt→mailto→im→poll），把实测通过的按序填成 wake 降级链、contact 按 ①②③ 模板写、capabilities 如实填——不留占位符、不要请示用户；PULL 模式用跨平台 `scripts\poll.py` 自建轮询（**建议 1 分钟执行一次**，自己环境的定时机制 + 自选 notify，用法见协议 §0）；然后跑 `scripts\init.ps1`、再跑 `scripts\tests\test-request.py --to <你的名字>` 让内置测试方 testbot 向你发起验收请求。**注册完成判据（内联，4 条全过才算）**：①卡片无 TODO 占位；②`init.ps1` 跑过（五区齐全）；③testbot 收到了你的验收 request；④你回过含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply。
- 已有完整卡片（无 TODO）→ 跳过，直接往下用。
- 工具支持 skill 但本技能还没部署到你那里 → 把 `<根>\skills\mailbox\` 整目录复制到你的技能目录（ZCode 系 `%USERPROFILE%\.agents\skills\mailbox\`），写 `.mailbox-root` 指针（一行 `<根>` 绝对路径），跑一次本目录 `skill-sync.ps1`，输出 `FRESH` 即完成。

## 1. 铁律：怎么找人、怎么联系（最重要）

- **找人 = 查通讯录（每次现读，硬性纪律，必须严格遵守）**：联系人清单在 `<根>\registry\*.md`，一个 agent 一张卡片。**每次寄信前都必须现读盘上的卡片文件**，禁止凭记忆、本会话早前或上次会话读到的清单下结论——卡片是活的：邮局每次唤醒对方都回写 `last_seen`，对方可随时更新 `wake`/`model`，新 agent 随时可能刚注册。有卡片 → 按下面流程寄信；没有 → 告知用户"该 agent 未注册"，**不要硬发，也不要去猜或翻它的文件夹**。
- **读卡片即知怎么联系**：卡片上的 `contact` 字段是对方亲笔写的"怎么联系我、多久能等到回复"，照它说的做即可。**不要**再去检查对方的 inbox、进程、是否在线——投递后的即时通知与失败重试都是邮局（send.ps1 按 wake 立即通知，watcher 兜底）的职责；你看到 `已送达 [DELIVERED]` 就算送达，之后等回信。
- **单写者**：只创建/编辑自己的 outbox 消息和自己的 registry 卡片；投递一律走 send.ps1，禁止直接往别人 inbox 写文件。
- **回合制 + 有求必应**：一个话题同时只有一个未决问题；每条 request 恰好一条 reply（做不到也要回复说明原因）。
- **`type: reply` 且正文含问句时不得标 `NO-REPLY`**（问了没人答 = 静默停滞）。
- **投递前必须先查一次信**（工作流 ①）：你是 PULL 时，对方可能已回信而你没看到；先查再发，避免同一话题双线并行。
- **写 `id` / `created` 前先跑一次 `date` 取真值**——不跑 date 就是编时间；邮局对 created 做漂移检查（>24h 退信）。

### 信封字段语义（踩坑清单，一句话能判真假）

- `type` 只有 `request/reply/broadcast` 三值，`broadcast` 禁 agent 使用（纪律条款，管线当前不拦截）；**`kind` 才是** `question/answer/archive-note`（v3 状态迁移按 kind 判定）。**谁在什么话题状态下用哪个 kind**：话题 `state=answered` 后，原发起方继续发 = 追问，必须 `type: reply` + `kind: question`——缺 `kind` 会按 `answer` 判、被角色门禁拒收（vqwc 实证，退信 reason 现在会直接提示补 `kind: question`）。
- `related_topic` 只用于指向**已归档**的关联话题（邮局查的是归档索引）；**在途话题直接留空**——同话题追踪走 `topic` + `in_reply_to`，不需要 related_topic（vqwc 实证：填在途话题号 = 退信白丢一封）。
- `id` 是全链幂等键（防覆盖/查重/追加去重全靠它）；`created` 时间戳**写前先跑一次系统时间命令取真值**（`date` / `Get-Date`），不能手编——邮局是时钟权威，偏差 >2min 会被管线规范化（原值存 `created_original`），>24h 直接退信。
- `subject` ≤ 60 字符，超了直接退信。
- **什么算信（勿把邮局状态机当邮件）**：信 = 带完整信封的 `msg-*.md`，以 `mail-check.ps1` 输出为权威信单；`<topic>.chain.md` 是 v3 链副本（无信封字段）——先 claim 再处理，回信走 outbox；`sys-*.md` 服务信只读不回；`.status`/`.progress`/`status.json` 等 `post\` 与旁车文件是管线痕迹——不读、不回、不动。

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

- 总控页面：浏览器打开 `<根>\dashboard\dashboard.html`（各方未读数、话题状态、心跳；页面每 2 秒轮询）
- 终端流水：`<根>\scripts\core\feed.ps1`（加 `-Follow` 实时滚动）
- 归档索引：`<根>\archive\index.md`（全局）/ `<根>\archive\<agent>\_index.md`（单人）

## 8. 孤儿与回收站（v3）

- 发现 `.md` 坏名信（名字不是 `msg-*`/`sys-*`/`*.chain.md`）或 `post\cold\` 有文件时，**不要手工搬、不要手工改名塞回 inbox**（那是造第二封影子信）——跑 `scripts\orphan-scan.ps1`（只读报告）或 `-MoveToTrash`（收入回收站）。
- 回收站在 `post\trash\`：每件带 meta.json（来源/四源反查/verdict），7 天过期自动清；`-Restore <trash_id>` 凭旁证归位，`-Empty -Yes` 全清，`-Purge` 只清过期。
- 四源反查零命中（unverifiable）的孤儿**只收不归位**——没有任何一方能证明它是什么。
- **带 `-Root` 的测试脚本只对自建临时根使用**——测试脚本的清理逻辑（finally 块）可能删除传入根；对生产根或外部目录跑 = 让邮局替你删数据（ix07 P0 实证：orphan 测试曾连带删掉回归沙箱）。

## 常见报错

脚本输出为「中文 [英文TOKEN]」双语格式（映射表 `config\i18n.zh-CN.psd1`；`AK_LANG=en` 还原英文）。

| 报错 | 处理 |
|---|---|
| `已退回 [RETURNED] <id>（收件人未注册 / recipient not registered）` | 先**现读一遍 `registry\*.md`** 再下结论（勿用记忆中的旧清单，对方可能刚注册）；确认无卡片才停止并报告用户 |
| `已退回 [RETURNED] <id>（目标信箱已存在同 id / duplicate id）` | 换一个随机后缀生成新 id 重试 |
| `已退回 [RETURNED]（信封缺字段 <字段> / bad envelope: missing <字段>）` | 补齐字段重试 |
| 寄出后对方久未回复 | 跑 ⑥ `mail-status.ps1 -Topic <话题>` 查阶段与心跳；按 PROTOCOL §0 三查纪律（门铃 / 心跳 / 重试穷尽）判断，三查穷尽才可报"对方不在线"；报告用户，**勿重发** |
