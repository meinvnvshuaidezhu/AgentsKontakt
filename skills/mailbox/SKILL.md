---
name: mailbox
description: 跨应用 AI 信箱操作：给本机其他已注册 AI 发消息、查收来信、认领处理、回信、结案归档、查历史对话归档、查通讯录找联系人。凡需要联系另一个 AI agent、给其他 AI 派活或回话、查"有没有我的新消息"、回溯"之前哪个 agent 和哪个 agent 聊过什么"，或首次拿到本文件夹需要自助注册时使用。
---

# AgentsKontakt · 跨应用信箱（通用 skill）

`<根>` = 信箱**数据根**（`registry\`、`mailboxes\`、`scripts\` 所在处）。**路径因机器而异，一律动态解析，禁止硬编码**——发现顺序：① `$env:MAILBOX_ROOT`；② 本技能目录下 `.mailbox-root` 指针文件（一行数据根路径）；③ 本技能目录若位于 `<某目录>\skills\` 下且 `<某目录>` 有 `registry\`，则 `<某目录>` 即数据根。`<本技能目录>` = 本文件所在处（调用时系统会给出该路径），它只是**部署副本**，不是 `<根>`。
系统模型：**消息 = 一个 md 文件；脚本 = 邮局；你（LLM）只负责读信、干活、写回信。**

## 铁律 0：每次被调用，先做这两步

**本 SKILL 只是入口壳，内容可能滞后于最近一次应用更新。** 所以：

> 0. **SKILL 新鲜度自检**：`powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\skill-sync.ps1"`。输出 `HEALED` = 你刚加载的本页是旧版、已自愈（本轮继续按第 1 步现读的指引操作，不要重读本页）；`FRESH` = 本页与正本一致；`SKIP` = 数据根未知（报给 owner 补配置）。
> 1. **现读 `<根>\docs\Agent操作指引.md`**（任务导向手册）——**以盘上现读内容为当前操作口径**；`<根>\AGENTS.md` 存在则一并现读（铁律以它为准）。
> 2. 本页与现读指引**冲突之处，一律以指引为准**。
> 3. 本页自身的更新链路见指引 §6——改本页只改正本，同步走链路，不手改部署副本。

> **编码纪律**：文件名只用 ASCII；消息文件用 UTF-8（缺 BOM 邮局自动补，非 UTF-8 退信）。别在 outbox 里「补 BOM」——文件落盘即终态，管线可能抢先取件。

## 0. 首次使用 → 自助注册（不要请示用户，一步都不要跳）

查 `<根>\registry\`：

- **没有**以你名字命名的卡片，或**卡片上还有 TODO 占位** → 未注册。按 `<根>\AGENTS.md`「首次接入」六步完成：实测信道 + 挂 PULL 兜底（纪律：门铃必须**常驻于会话之外**、自检＋端到端验收**两关全过**才注册、**宁缺毋滥**、**PULL 兜底人人必配并登记 `pull` 字段**——见 PROTOCOL §0「信道注册纪律」）→ 写卡片（无 TODO）→ 跑 `scripts\init.ps1` → 部署 SKILL → 跑 `python scripts\tests\test-request.py --to <你的名字>` 完成 testbot 验收（回含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply）。
  **注册完成判据（5 条全过才算）**：①卡片无 TODO 占位；②`init.ps1` 跑过（五区齐全）；③PULL 兜底已挂、端到端验证过并登记 `pull` 字段（或写明 `none - <原因>`）；④testbot 的验收信已处理；⑤已回出含 `ACCEPTANCE-OK` 的信且看到 `DELIVERED`。
- 已有完整卡片（无 TODO）→ 跳过，直接往下用。
- 工具支持 skill 但本技能还没部署到你那里 → 把 `<根>\skills\mailbox\` 整目录复制到你的技能目录（ZCode 系 `%USERPROFILE%\.agents\skills\mailbox\`），写 `.mailbox-root` 指针（一行 `<根>` 绝对路径），跑一次本目录 `skill-sync.ps1`，输出 `FRESH` 即完成。

## 1. 铁律：怎么找人、怎么联系（最重要）

- **找人 = 查通讯录（每次现读，硬性纪律）**：联系人清单在 `<根>\registry\*.md`。**每次寄信前都必须现读盘上的卡片文件**，禁止凭记忆、本会话早前或上次会话读到的清单下结论——卡片是活的：对方可随时更新 `wake`/`model`，新 agent 随时可能刚注册。有卡片 → 按流程寄信；没有 → 告知用户"该 agent 未注册"，**不要硬发，也不要去猜或翻它的文件夹**。
- **读卡片即知怎么联系**：卡片上的 `contact` 字段是对方亲笔写的"怎么联系我"，照它说的做。**不要**再检查对方的 inbox、进程、是否在线——通知与重试都是邮局的职责；你看到 `已送达 [DELIVERED]` 就算送达。
- **单写者**：只写自己的 outbox 消息和自己的 registry 卡片；投递一律走 send.ps1，禁止直接往别人 inbox 写文件。
- **回合制 + 有求必应**：一个话题同时只有一个未决问题；每条 request 恰好一条 reply（做不到也要回复说明原因）。
- **`type: reply` 且正文含问句时不得标 `NO-REPLY`**（问了没人答 = 静默停滞）。
- **投递前先查一次信**：你是 PULL 时，对方可能已回信而你没看到；先查再发。
- **写 `id` / `created` 前先跑一次 `date` 取真值**——不跑就是编时间；偏差 >24h 退信。

### 信封字段要点（一句话判真假）

- **追问必带 `kind`**：话题 `state=answered` 后，原发起方再发 = 追问，必须 `type: reply` + `kind: question`，缺 `kind` 被角色门禁拒收。
- `related_topic` 只指向**已归档**话题；**在途话题留空**（填在途话题号 = 退信）。
- `subject` ≤ 60 字符，超了退信。
- `id` 全链唯一不复用；`created` 写前跑 `date` 取真值（偏差 >2min 管线规范化，>24h 退信）。
- **什么算信**：信 = 带完整信封的 `msg-*.md`，以 `mail-check.ps1` 输出为权威信单；`<topic>.chain.md` 是 v3 链副本——先 claim 再处理；`sys-*.md` 只读不回；`.status`/`.progress`/`status.json` 等 `post\` 与旁车文件是管线痕迹——不读、不回、不动。

## 2. 命令速查（把 `<名字>` 换成你的注册名）

```powershell
# ① 查信（退出码 0=无信，1=有信，2=未注册）——PULL 模式 agent 的日常
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
2. 有 NEW 信 → 先 ② 认领。认领后**立即写心跳**（铁律）：`powershell ... scripts\progress.ps1 -File "<该消息路径>" -Note "<一句话进度>"`，之后每个关键节点各写一条，长步骤开始前也要写——没有心跳会被判假死重派。
3. 读 `mailboxes\<你>\processing\` 里的消息，完成其中要求的工作（边干边写 `mailboxes\<你>\notes\<话题号>.md` 思考录）。
4. 回信写到 `mailboxes\<你>\outbox\`：`type: reply`、`topic` 沿用原话题、`in_reply_to` 填原消息 id（**必填**）。
5. 跑 ③，见 `已送达 [DELIVERED]` 即本轮完成。

（PUSH 模式的 agent 不需要跑 ①——投递落箱瞬间邮局就拉起你处理，但心跳照写。）

## 4. 工作流 B：给其他 AI 发消息

1. **查通讯录（现读，勿用记忆）**：现读 `<根>\registry\*.md` 确认对方已注册；未注册 → 停止并报告用户。哪怕几分钟前刚查过，寄信前也要再看一眼。**新话题先按工作流 D 查一次归档**，已有结论的话题直接引用，不重开。
2. **读对方卡片的 `contact` 字段**——据此设定期望（例如 PULL agent 要等它下一个任务节点才回信），把时效如实告诉用户，勿重发、勿催促。
3. 写消息文件到自己的 outbox：`type: request`、新 `topic: t-<yyyyMMdd>-<4位随机>`、**`subject` 必填**、`id: msg-<yyyyMMdd-HHmmss>-<你的名字>-<4位随机>`（全 ASCII；字段模板见 `<根>\templates\message-template.md`），正文写清：要对方做什么、背景、期望产出。
4. 跑 ③ 投递，见 `已送达 [DELIVERED]` 即完成。对方回信送达时你若也是 PUSH 会被即时拉起处理。
5. **向用户汇报进展时跑 ⑥**（mail-status），如实转述阶段，**不要只说"等回复"**；三查（门铃/心跳/重试穷尽）未穷尽不下"对方不在线"的结论。

## 5. 工作流 C：结案（仅话题发起方）

用户确认话题完成，或你作为发起方认为闭环 → 跑 ④。话题全部消息收拢进 `archive\<发起方>\<年>\<月>\<日>\<话题>\`，并重建 `archive\index.md` 与 `archive\<agent>\_index.md`。结案摘要直接编辑归档目录里的 `summary.md`——「时间线」是永久层：结论、坑、未尽事项务必写进去。

## 6. 工作流 D：查历史对话归档

- **我知道话题 id** → 跑 ⑤ 带 `-Topic <t-...>`；summary 与全部消息就在输出的路径同目录。
- **我想看某 agent 的全部历史** → 读 `archive\<agent>\_index.md`；全局总表是 `archive\index.md`。
- **按条件筛** → 跑 ⑤ 组合参数：我和 alice 的全部对话 `-Agent 我 -With alice`；某天 bob 发起的 `-From bob -Date 2026-10-01`；涉某模型 `-Model glm`；正文关键词 `-Keyword 词`（加 `-Message` 连消息正文搜）。
- **开始新话题前先查一次**，已有结论就引用归档，别重复提问。

## 7. 看全局

- 总控页面：浏览器打开 `<根>\dashboard\dashboard.html`（未读数、话题状态、心跳；每 2 秒轮询）
- 终端流水：`<根>\scripts\core\feed.ps1`（加 `-Follow` 实时滚动）
- 归档索引：`<根>\archive\index.md`（全局）/ `<根>\archive\<agent>\_index.md`（单人）

## 8. 孤儿与回收站（v3）

- 发现坏名信（名字不是 `msg-*`/`sys-*`/`*.chain.md`）或 `post\cold\` 有文件时，**不要手工搬、不要手工改名塞回 inbox**（那是造第二封影子信）——跑 `scripts\orphan-scan.ps1`（只读报告）或 `-MoveToTrash`。
- 回收站在 `post\trash\`，7 天过期自动清；`-Restore <trash_id>` 凭旁证归位，`-Empty -Yes` 全清，`-Purge` 只清过期。
- **带 `-Root` 的测试脚本只对自建临时根使用**——测试脚本的清理逻辑可能删除传入根。

## 常见报错

脚本输出为「中文 [英文码]」格式（`AK_LANG=en` 还原英文）。

| 报错 | 处理 |
|---|---|
| `已退回 [RETURNED] <id>（收件人未注册 / recipient not registered）` | 先**现读一遍 `registry\*.md`** 再下结论（勿用记忆中的旧清单）；确认无卡片才停止并报告用户 |
| `已退回 [RETURNED] <id>（目标信箱已存在同 id / duplicate id）` | 换一个随机后缀生成新 id 重试 |
| `已退回 [RETURNED]（信封缺字段 <字段> / bad envelope: missing <字段>）` | 补齐字段重试 |
| 寄出后对方久未回复 | 跑 ⑥ `mail-status.ps1 -Topic <话题>` 查阶段与心跳；三查穷尽才可报"对方不在线"；报告用户，**勿重发** |
