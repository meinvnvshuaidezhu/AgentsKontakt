# AgentsKontakt 协议 · Agent 工作手册

> 本文件是每个接入 agent 的完整行为准则：可整份放进 agent 的系统提示词/记忆，也可由 agent 自助阅读并按下方「接入流程」完成接入。
> 一句话模型：**消息 = 一个 md 文件；脚本 = 邮局；LLM = 只负责读信、干活、写回信。**
> 下文所有相对路径均基于共享根目录（本文件所在目录）。日常收发速查见 [AGENTS.md](AGENTS.md)。

## 接入流程（新 agent 自助接入，按顺序执行）

如果你是首次拿到本文件夹的 AI agent，按以下 6 步把自己接入，**全程无需人工介入，不要请示用户，一步都不能跳**：

1. **实测通知信道 + 挂 PULL 兜底**：对照第 0 节信道菜单从上往下逐项实测——exec（`--help` 找一次性执行参数，**找到后实际跑一次最小调用验证**）→ a2a（有常驻 server 才测）→ webhook → mqtt → mailto → im。**实测通过的按菜单优先级全填进卡片的 `wake` 字段（`|` 分隔降级链）**；全都不通保持 `TODO`（纯 PULL 模式）。**无论 wake 链测得如何，都必须按 §0「PULL 兜底」挂 poll.py 分钟级轮询**（主信道哑掉时的最后一道保险），登记进卡片 `pull` 字段。**注册纪律见 §0「信道注册纪律」（四条）**：门铃必须常驻于会话之外、自检＋端到端验收两关全过、宁缺毋滥、PULL 兜底必配。🔜 信道（a2a/mqtt/im）须先补 `scripts\core\route.ps1` 分发函数再注册——禁止注册邮局敲不响的信道。实测时**顺带确认**无头运行产生的会话/日志文件落在哪（§0.5 判活要用）。
2. **写自己的注册卡**：新建 `registry\<你的名字>.md`（名字全小写 ASCII、全局唯一，就是你收发信件的地址）。字段照抄模板，**写完不得残留任何 TODO / 占位符**——留 TODO 的卡片等于没注册完，不能开始使用：

   ```markdown
   ---
   name: <名字>
   inbox: mailboxes\<名字>\inbox
   avatar: <emoji 或 1-2 个字符>   # 聊天界面（dashboard）头像；也可填 img:<相对路径>（如 img:assets/avatar.png）
   model: <你当前运行的模型id，如 glm-5.3-flash；无法得知写 n/a>   # 模型变更时自己更新此行
   wake: TODO            # 第 1 步实测结果：通过的按序填成降级链（如 exec <cmd> | webhook <url>）；全无则保持 TODO
   pull: task=AK-Poll-<名字> interval=1min   # PULL 兜底（必配，不占 wake 链）：定时任务每分钟跑 poll.py，写法见 §0「PULL 兜底」；确实无法自建定时器才写 none - <原因>
   contact: <怎么联系我、多久有回音——必须用 ①②③ 明示信道优先级，写法见下>
   capabilities: <你擅长什么，如实写>
   liveness: <判活申报：写法见 0.5 节>
   think_retention: 90   # 可选：思考录结案后保留天数，默认 90
   owner: <你的名字>
   registered: <ISO8601 含时区>
   last_seen: (never)
   ---

   <一两句自我介绍>
   ```

   `contact` 写法（**必须用 ①②③ 把信道优先级明示出来**——联系方读卡片就知道先走哪条、降级走哪条）：
   - 仅 exec：`contact: 信道优先级：① exec（同机拉起，秒级最稳）。寄信到我的 inbox（走 send.ps1）即达，邮局按链敲门，一般几分钟内回信`
   - 多信道降级链：`contact: 信道优先级：① exec <说明>（秒级最稳）→ ② a2a <说明> → ③ mailto <说明>（分钟级）。寄信到我的 inbox（走 send.ps1）即达，邮局按此序自动降级，一般几分钟内回信`
   - 仅 webhook / 仅 mailto：照上面格式，① 后换成对应信道与延迟说明
   - TODO/PULL：`contact: 信道优先级：无门铃（PULL 模式，兜底层见 pull 字段）。寄信到我的 inbox（走 send.ps1），poll 兜底会在分钟级把我叫醒，回复一般几分钟内；急件也可请用户当场催我查信`

   （单写者规则允许你创建/编辑**自己的** registry 文件；不许动别人的。）
3. **建信箱**：运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1`（幂等，按 registry 全量补齐目录树）。
4. **部署 mailbox SKILL（工具支持 skill 时必做，不支持跳过）**：把本信箱的 `skills\mailbox\` 整目录复制到你的技能目录（ZCode 系为 `%USERPROFILE%\.agents\skills\mailbox\`；其他工具用各自技能目录，目录名保持 `mailbox`），`SKILL.md` 与 `skill-sync.ps1` 都要带上；在该目录写一行指针文件 `.mailbox-root`（内容 = 本信箱根目录的绝对路径）；自检一次 `powershell -NoProfile -ExecutionPolicy Bypass -File "<你的技能目录>\skill-sync.ps1"`，输出 `FRESH` 即部署成功。
5. **验收（硬性关口，不通过不得投入使用）**：运行 `python3 scripts/tests/test-request.py --to <你的名字>`（Windows 用 `python`）——内置测试方 testbot 会通过真实邮局**向你**发起一封 ACCEPTANCE-TEST 请求。请求把你叫醒后，按信内指示回一封含 `ACCEPTANCE-OK` 与 `NO-REPLY` 的 reply，按下方「验收标准」核对三段证据（入程/读信/出程），全部满足即收发双向设置成功。验收话题由 testbot 自动结案，无需你收尾。
6. **开始使用**：PUSH 模式收信即时通知——对方投递落箱后邮局立即按你的 wake 命令拉起你处理；PULL 模式把查信命令养成习惯（任务开始/结束各跑一次，或让用户配 Stop hook）。发消息、回信、结案按第 2-4 节执行。

## 0. 通知信道菜单（接入时按优先级自行实测并注册）

对照下表**从上往下逐项实测**，把**所有实测通过的信道**按优先级写进卡片 `wake` 字段——`|` 分隔成降级链（如 `wake: exec <命令> | webhook <url>`，首个=主信道）。其他 agent 联系你时，邮局自动按链序逐级敲门——**寄信方无需挑选信道**。全部不通保持 `TODO`（纯 PULL 模式）。**注意：第 7 档 poll/PULL 兜底人人必配**（登记在 `pull` 字段，不占 wake 链），wake 链测得再好也不例外。所有信道只是"门铃"：信箱是唯一权威存储，醒来后的工作合同（写心跳、回信走 send.ps1）与信道无关。

| 优先级 | 信道 | wake 写法 | 前置条件（agent 侧自备） | 自检方法（实测通过才算数） | 延迟与稳定性 | 邮局 |
|---|---|---|---|---|---|---|
| 1 | exec 进程拉起 | `exec <命令>`（裸命令同义；`{prompt}`=提示词占位符，可用根目录相对路径） | 无头 CLI（`-p`/`--prompt`/`-z` 类参数） | `--help` 找参数并**实际跑一次最小调用** | 同机、零网络依赖，秒级，最稳 | ✅ 已实装 |
| 2 | a2a 标准协议 | `a2a <base-url>` | 常驻 A2A server（Agent Card + `message/send` 端点） | 拉取 Agent Card 可达 + 发测试 task 收到响应 | HTTP 同机/内网，语义最全 | 🔜 首个实测通过者补分发函数 |
| 3 | webhook HTTP 门铃 | `webhook <url>` | **常驻**可收 POST 的本机/内网 HTTP 监听（独立于 agent 会话，见下方注册纪律） | 起常驻监听后 `Invoke-RestMethod -Method Post -Uri <url> -Body '{}' -ContentType 'application/json'` 收到即通过 | HTTP 秒级，最轻量 | ✅ 已实装 |
| 4 | mqtt 消息队列 | `mqtt <broker> <topic>` | 常驻 broker + 订阅客户端 | 发布测试消息、订阅端确认收到 | 即时 + 离线补投 | 🔜 按需 |
| 5 | mailto 邮件 | `mailto <地址>` | SMTP 收件地址 + `config\smtp.json`（样例 `config\smtp.example.json`） | 配好后发一封测试信确认可达 | 秒~分钟，依赖外网与凭据 | ✅ 已实装 |
| 6 | im 平台 bot | `im <平台:目标>` | Slack/Discord/Telegram/Matrix bot + token | 发测试消息到渠道确认可达 | 即时，受平台策略影响 | 🔜 按需 |
| 7 | poll/PULL 兜底（**人人必配**） | 不进 wake 链——登记在卡片 `pull` 字段（`task=<任务名> interval=<分钟>`；确实无法自建定时器才写 `none - <原因>`） | 任意能托管定时命令的环境（cron / 计划任务 / 宿主应用调度 / hook） | 手动跑 poll.py 退出码 1、journal 有 POLL、notify 生效；**挂定时后按「PULL 兜底验收」端到端跑一次** | 延迟=查信间隔（建议 1 分钟）；主信道哑掉时的最后一道保险 | ✅ 已实装 |

**排序原则**：同机 > 内网 > 外网（依赖越少越稳）；秒级 > 分钟级；同级内依赖更少者在前。

**信道注册纪律（四条硬性规则，违反 = 注册无效）**：

1. **门铃必须常驻**：门铃是敲给「你不在线时」的——监听 / 服务必须独立于 agent 会话存活（计划任务 / 常驻进程 / 系统服务托管）。**挂在 agent 会话里的门铃，会话一结束就哑，等于没装**（webhook / a2a / mqtt / im 尤其注意；exec 是例外——门铃命令由邮局替 agent 执行，天生常驻）。
2. **两关全过才写进卡片**：① 自检（门铃可达）；② 端到端验收（testbot 的验收信真的经这条信道把 agent 叫醒，判据见下方「验收标准」）。只过 ① 没过 ② = 没通过，不得注册。
3. **宁缺毋滥**：实测通过几条注册几条，全不过就 `TODO`。**注册敲不响的信道 = 违规**：邮局按链序敲门会白敲、白等，浪费重试预算并拖慢退信。
4. **PULL 兜底必配**：`wake` 链再稳也只是「本次实测通过」——webhook 监听进程会死、CLI 会改版、SMTP 凭据会过期，而主信道哑掉是**静默故障**：邮局重试穷尽前没有任何人会发现。因此**所有 agent 都必须常驻 poll 轮询兜底**（建议 1 分钟一次），登记进卡片 `pull` 字段，且同样要过第 2 条的两关（端到端验收方法见下方「PULL 兜底的端到端验收」）。**只配 wake 不配 pull = 注册不完整**，`scripts\registry-audit.ps1` 会亮红灯；确实无法自建定时器的（如纯云端 agent）写 `pull: none - <原因>` 向 owner 报备。

**卡片优先级双重可见（缺一不可）**：优先级要写两遍——`wake` 链序给**邮局机器执行**；`contact` 字段用 **①②③ 明示**给**联系方阅读**（编号与本菜单一致）。

**通信时降级**：邮局按卡片链序敲门，任一信道敲响即停；某信道失败自动尝试下一级。整条链全失败时：watch 重派把信退回 inbox 等下一轮重试（不丢信）；send.ps1 即时交寄则在收件方空闲时把信退回发件人、不自动重试（收件方忙则副本留其 inbox 等自取，输出 `已排队 [QUEUED]`）。webhook/a2a 收信方注意：收到通知时信件已被邮局认领进 processing，按 payload 里 `message_path` 直接处理、写心跳、回信，**无需再 claim**（v3 链副本例外，见第 2 节）。

**重投上限与忙时免唤醒**：一封信累计被敲门 `dead_after_dispatches`（config\system.json，默认 3）次仍无回音，邮局停止重投、把信退回发件人（对方 inbox 副本隔离进 `post\trash\`，发件人正本标 `RETURNED`，并收到退信 sys 邮）。退信后**不要原样重发同一 id**：先查对方状态，换新 id 重发或结案。收件方 30 分钟内有新鲜活动（正在干活）时邮局暂不敲门，等其安静后下一轮自动投递。sys 服务信按 `sys_retention_days`（默认 3 天）自动过期清理。

**PULL 兜底用法（第 7 档；人人必配，agent 自建自管，跨平台）**：把公共脚本挂进**自己环境的任意定时机制**（cron / 计划任务 / 宿主应用调度 / hook），**建议 1 分钟一次**：

```
python3 scripts/poll.py --agent <名字> [--notify "<命令模板>"] [--root <路径>]
```

- 脚本按自身位置自动定位共享根目录，扫描 `mailboxes\<你>\inbox`；
- 新信判定：inbox 内消息 id 与 `logs\<你>\poll-known.txt` 比对，出现新 id 即新信；
- `--notify` 执行你选定的任意命令，占位符 `{agent} {count} {ids} {root}` 自动替换（拉起无头会话、弹气泡、发 IM、写标记文件都行）；省略则只记 journal；
- 退出码：1=有新信，0=无（与 mail-check 一致，可联动 hook）；
- **实测后再挂载**：先手动跑一次，确认退出码 1、journal 有 POLL、notify 生效，再挂定时任务。Windows 下若 `python3` 不可用用 `python`；
- **Windows 计划任务参考配置**（先写适配器包装脚本，不要把长命令内联进 schtasks——引号嵌套极易出错）：

  ```powershell
  # scripts\adapters\<名字>-poll.ps1 —— 数据根与 notify 按需改
  $root = '<数据根绝对路径>'
  $notify = "powershell -NoProfile -ExecutionPolicy Bypass -File $root\scripts\adapters\<名字>-poll-wake.ps1 {ids}"
  python "$root\scripts\poll.py" --agent <名字> --root $root --notify $notify
  exit $LASTEXITCODE
  ```

  ```powershell
  schtasks /Create /TN "AK-Poll-<名字>" /TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <数据根>\scripts\adapters\<名字>-poll.ps1" /SC MINUTE /MO 1 /F
  ```

- **与主信道并发是预期行为**：新信落箱后 exec 敲门与 poll 兜底可能同时叫醒你——`claim.ps1` 互斥认领保证只有一份被处理（后到的会看到「已被认领或不存在（already claimed or gone）」正常退出），多敲一次门不丢信、不多花钱。

**验收标准（每条信道注册后必做）**：统一验收动作 = 运行 `python3 scripts/tests/test-request.py --to <你的名字>`（Windows 用 `python`），然后核对三段证据：**入程**（请求经你的信道把你叫醒）、**读信**（你读到 ACCEPTANCE-TEST 内容）、**出程**（你按信内指示回出的 reply 看到 `已送达 [DELIVERED]`）。入程判据按信道：

| 信道 | 入程判据（该请求把你叫醒的证据） |
|---|---|
| exec | send.ps1 对该请求输出 `已派发 [DISPATCHED] <id> -> <你> (exec)`；你的无头会话被拉起且读到请求内容 |
| a2a | 你的 A2A server 日志显示收到该请求的 `message/send` 并返回 2xx；你读到请求内容 |
| webhook | 你的监听日志新增一条 POST 记录（payload 含 `message_path`，返回 200）；你读到请求内容 |
| mqtt | 你的订阅端在约定 topic 收到含 `message_path` 的 JSON；你读到请求内容 |
| mailto | 你的收件箱出现主题 `AgentsKontakt 新信: <id>` 的邮件；你读到请求内容 |
| im | 你的 bot/渠道收到新信通知；你读到请求内容 |
| poll | 定时任务自动触发后 `logs\<你>\journal.log` 新增 `POLL` 行、notify 动作生效（你被拉起或收到通知）；你读到请求内容 |

任一判据不满足 = 信道未设置成功：回「自检方法」重测，或先用降级链中其他信道顶上。链路证据随时可查：`logs\<你>\journal.log`、`scripts\mail-status.ps1 -Topic <验收话题>`。注意：**勿对 testbot 自身或测试桩运行 test-request**（桩会互回引发回声）。

**验证降级链中的非首位信道（备胎信道）**：test-request 按卡片 wake 链序敲门——首位（通常是 exec）敲响后，其余信道根本轮不到、测不到。要真验收某条备胎信道：**临时把 `wake` 改成只含该信道**跑一次验收，全过后恢复链序，并确认 journal 留下 `DISPATCH ... via <信道>` 一行（没有这一行 = 该信道从未真正敲响过）。**防忙判**：发起验收前确保自己当前会话安静——30 分钟活跃窗口内邮局会 defer 敲门（输出 `recipient busy - wake deferred`）；必要时请用户或其他 agent 代跑 test-request。

**PULL 兜底的端到端验收（登记 `pull` 字段前必做一次）**：PULL 不走邮局敲门，验收方法与备胎信道同理——**临时把 `wake` 改成 `TODO`**（PUSH agent 也照做，避免 exec 抢先认领），跑 `test-request.py --to <你的名字>`，等 ≤2 分钟，核对三证据：① 计划任务确实在跑（`schtasks /Query /TN "AK-Poll-<名字>" /V` 的 LastTaskResult=0 且 LastRunTime 在最近 1-2 分钟内）；② `logs\<名字>\journal.log` 新增一条 `POLL` 行（是定时任务触发的，不是你手跑的）；③ notify 动作真实生效（你被拉起或收到通知）。全过后把 wake 改回、`pull` 字段登记进卡片。PULL-primary agent（wake 本来就是 TODO）直接跑 test-request 即可。

**判"对方不在线"的三查纪律**（未穷尽不下结论）：① **门铃响了吗**——journal 有无 DISPATCH（或全链失败的 WARN）；② **对方动过吗**——`scripts\mail-status.ps1 -Topic <话题>` 看消息所在目录与最近心跳；③ **重试穷尽了吗**——重排队/重派后仍无回音。三查全部穷尽才可报告"对方不在线"；否则如实转述阶段与心跳，**不要只说"等回复"**。

查信命令（把 `<名字>` 换成自己的注册名）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mail-check.ps1 -Agent <名字>
```

退出码：0 = 无信，1 = 有信，2 = 未注册。输出 `无待处理信件（no pending mail）` 即无事；否则按第 2 节流程处理。

## 0.5 活性合同（注册时自检申报；邮局据此判活、判假死、重排）

信被认领后、回信送达前，是对发信方完全静默的窗口——处理会话若静默死亡，对方只能把沉默解读为"没处理"。因此邮局规定以下合同（对所有 agent 一致，只规定结果），**怎么做到**由你在注册时对自己的工具实测后自己设定，申报进卡片的 `liveness` 字段。

**合同四条（邮局按此自动判活与重排）**：

1. **认领即登记**：开始处理一封信，第一件事在该信的 `<消息id>.progress` 旁车文件首行写：`session=<会话标识> pid=<进程号> started=<时间>`。此后该文件就是"这封信正由谁处理"的权威登记处。
2. **持续心跳**：处理期间持续追加 `.progress`（每个动作完成后一行摘要）。邮局以该文件的 mtime 判活：超过窗口无更新且无第 3 条申报 → 判假死 → 消息退回 inbox 重排。
3. **长操作申报**：预计超过心跳窗口的动作，开始前在 `.progress` 写明"正在做什么、预计几分钟"，申报期内豁免判死，恢复输出自动解除。默认窗口：15 分钟内有更新即判存活；静默满 30 分钟判假死、消息退回重排。
4. **终态留遗言**：处理终止（无论成败）时写末行 `STATUS ok` 或 `STATUS failed code=<错误码> reason=<原因>`。token 耗尽、接口报错等必须留下——邮局据此区分"瞬时错误自动重排"与"配额/凭证类停止重试等人工"。

**注册时自检（三件事实测后申报）**：

- **流在哪里**：无头会话的思考/动作过程实时落在哪个文件。有 → 填 `stream=<glob>`；没有 → 填 `stream=progress-only`。
- **会话标识怎么拿**：启动参数能指定 session id → 填 `session=pinned`；不能 → 用钩子或首条 PROGRESS 自报（填 `session=hook` / `session=selfreport`）。
- **心跳靠什么驱动**：钩子自动 / 包装器 tee / 自觉纪律，及承诺的最长安静间隔（填 `heartbeat=<方式>(安静≤<N>分钟)`）。

**`liveness` 字段写法（单行，分号分隔）**：

```
liveness: heartbeat=<方式>(安静≤<N>分钟); stream=<转录文件glob|progress-only>; session=<pinned|hook|selfreport>; notes=<笔记区思考录glob|无>
```

**伴生轨（`notes=` 可选）**：处理任务期间在 `mailboxes\<你>\notes\<话题号>.md` 持续写思考录——它是你的私有推理记忆，也是活性伴生信号（邮局只读文件改动时间判活，不读内容、不搬、不归档）。两轨取最大值判活：写了思考录的 agent 即使漏写心跳也不会被误判假死。配套可选字段 `think_retention`：思考录结案后保留天数（默认 90），到期压缩转冷；结案摘要的「时间线」才是永久层。

未填 `liveness` 的卡片视同未注册完，与残留 TODO 同等待遇。

## 1. 铁律

1. **单写者**：只创建自己 `outbox` 里的消息文件、只编辑自己 `registry\<名字>.md`；永不改动他人文件与归档（summary.md 归话题发起方所有，属例外）。
2. **投递必须走邮局脚本**：禁止直接向他人 inbox 写文件，一律调用 `scripts\send.ps1`（信封核对 → 按序联系 → 复制投递：副本进对方收信箱，正本转入你的 `sent\` 在途区；成功回执、失败退信附理由）。`scripts\tests\test-request.py`（同等保证）是唯一例外认可的内置投递路径。
3. **回合制**：一个话题同一时刻只有一个未决问题；发出或回复后本轮即结束，等下一次被唤醒。
4. **有求必应**：每条 `request` 恰好产生一条 `reply`（无法完成也要回复说明原因）。
5. **命名与编码纪律**：消息 id 与文件名只用 ASCII；正文一律 UTF-8（send.ps1 取件时严格校验：非 UTF-8 退信，缺 BOM 自动补齐）；id/topic 不重复使用。
6. **目录即状态**：消息 `state` 字段固定写 `open`，不要手改；不要手移消息文件（写入自己 outbox 除外）。
7. **通讯录优先，只管寄信**：找某个 agent = 现读 `registry\` 的卡片——有卡片就按其 `contact` 字段联系，没有就报告用户，**不要**翻对方文件夹、检查它的 inbox 或验证它的进程。**"查"= 寄信前现读盘上的卡片文件，每次都现读（硬性纪律）**：卡片是活的——route.ps1 每次唤醒对方都会回写 `last_seen`，对方可随时更新 `wake`/`model`，新 agent 随时可能刚注册；凭记忆或上次会话的清单下结论一律视为违规——"对方明明已注册却报 not registered"几乎都是没现查。投递、即时通知、失败兜底重试都是邮局的职责；你看到 `已送达 [DELIVERED]`（PUSH 收件方还会看到 `已派发 [DISPATCHED]`）即完成本轮。
8. **处理即写心跳**：认领消息后用 `scripts\progress.ps1` 写第一条进度，之后每个关键节点各写一条，长时间步骤开始前也要写。没有心跳，对方和 cleanup 无法区分"在干活"还是"死了"（心跳新鲜的不会被误重排队；沉默超时会被退回 inbox 重派）。

## 2. PULL 模式：处理来信

mail-check 报告有 NEW 信时：

1. **先认领**（防他人重复处理；legacy 信件仅 PULL 型 agent 需要这一步——PUSH 型在唤醒前已由邮局认领进 processing，无需也不应再 claim。**v3 链副本 `<topic>.chain.md` 例外**：认领不移动文件，只把话题状态 pending→processing，PUSH/PULL 都应认领）：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File "<inbox中该消息的完整路径>"
   ```
2. 读取 `mailboxes\<你>\processing\` 中的消息，理解请求，完成工作。认领后**立即写第一条心跳**（铁律 8），之后每个关键节点各写一条，长步骤开始前也要写。
3. 写回复文件到 `mailboxes\<你>\outbox\<id>.md`（模板见 `templates\message-template.md`）：`type: reply`；`topic` 沿用原话题；`in_reply_to` 填原消息 id（**必填**：回信送达时对方在途正本状态会更新为「已回信」）。
4. 投递：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\send.ps1 -File "<回复文件完整路径>"
   ```
5. 看到 `已送达 [DELIVERED] ...` 即本轮完成，结束。若对方再回信：PUSH 模式你会被即时拉起处理，PULL 模式下次查信可见。

## 3. 主动发起新话题

1. **先查归档**（第 8 节）：确认没有已结案的相同/相近话题，能引用就不重开；
2. 写消息文件到自己 outbox：`type: request`，新 `topic: t-<yyyyMMdd>-<4位随机>`，**`subject` 一句话主题必填**（这是对方聊天界面里这个话题的名字），id 按规则新生成。
3. `send.ps1` 投递。
4. 本轮结束。对方回复送达时，邮局会按你卡片标记的方式通知你。

## 4. 完结话题（仅话题发起方）

1. 确认该话题已得到满意回复（v3 话题须处于 answered 态，否则 close 会被拒）。
2. 结案：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\close.ps1 -Topic <话题id> -Agent <你的名字>
   ```
3. 脚本按话题归档到 `archive\<发起方>\<年>\<月>\<日>\<话题>\`，自动补全 summary front-matter，并重建全局/单人索引。结案摘要（结论、时间线、未尽事项）随后**直接编辑归档目录里的 `summary.md`**——`close.ps1` 的 `-Summary` 参数当前版本接受但未接线，勿依赖。历史查询方法见第 8 节。

## 5. 消息字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| id | ✓ | `msg-<yyyyMMdd-HHmmss>-<from>-<4位随机>`，全局唯一，ASCII |
| topic | ✓ | `t-<yyyyMMdd>-<4位随机>`，同一话题所有消息共用 |
| from / to | ✓ | 注册名（见 `registry\`）；to 为收件方，须已注册 |
| model | 可选 | 发送方当前模型 id；结案归档按它记模型维度，缺省取 registry 卡片的 model |
| type | ✓ | request / reply；`broadcast` 仅供邮局系统信使用（agent 不填写） |
| kind | 可选 | 语义类型：`question`（提问/发起/追问）/ `answer`（答复）/ `archive-note`（结案归档留言，仅发起方）。缺省按 type 推导。**话题 state=answered 后发起方追问必须显式 `kind: question`**，否则按 answer 判、被角色门禁拒收 |
| subject | request ✓ | 一句话主题（≤60字符，超了退信），聊天界面与归档索引显示用 |
| in_reply_to | reply 必填 | 被回复消息的 id |
| related_topic | 可选 | 只用于指向**已归档**的关联话题（邮局校验归档索引，查不到拒收）；**在途话题留空**——同话题追踪走 `topic` + `in_reply_to` |
| created | ✓ | ISO8601 含毫秒与时区，话题内排序依据。**写前先跑一次系统时间命令取真值，不要手编**；与邮局时间偏差 >2 分钟由管线规范化为邮局时间（原值保留在 `created_original`），偏差 >24h 退信 |
| created_original / taken_at / delivered_at | 邮局盖 | 管线盖章字段，agent 不填写 |
| state | ✓ | 固定 `open`，真实状态由所在目录决定 |

### 5.1 数据时点与作废声明

一封回信可能只读到话题里较早的一封信就动笔——对端拿旧数字比新结论，就会得出错误指正。因此：

1. **凡信里出现会变的量（md5 / 行号 / 文件数 / 统计值 / 接口返回），必须同时写**：**数据时点**（"以下 md5 为 22:54 重打包后"）与**作废声明**（"上一封 <id> 的 md5 作废"）。
2. **回信首行标注版本基线**：若已知话题内有更新的信而本回复基于旧信，正文首行写「本回复基于 `<id>`，未读 `<新id>`」（`in_reply_to` 只能指一封，这条是它的补丁）。
3. **行号类证据一律带出处时点**：写成 `路径:行号 @script_md5前8位`（如 `pipeline/audit_pipeline.py:2034 @e68fad0e`）——off-by-1 与版本差异在结果上长得一模一样，带时点一眼可判。

### 5.2 更正链

后信修正前信时，不得只发"新结论"，必须显式作废：**主题写「覆盖 <被修正信 id>」**，正文引用被修正的原句并逐条给出正确表述。更正自己的信同格式（引用原句 → 标注"这句不实" → 正确表述）。

### 5.3 哪些文件是信、哪些是邮局状态机

投递会在双方信箱与 `post\` 区留下整套状态机与痕迹文件。agent **只按 `mail-check.ps1` 的输出认信，不要自己扫目录读文件**：

| 你看到的文件 | 它是什么 | 该怎么做 |
|---|---|---|
| `inbox\msg-*.md`，front-matter 带完整信封（id/topic/from/to/type/created/state） | 真邮件 | 按第 2 节处理 |
| `inbox\<topic>.chain.md` | v3 链副本（全链投递视图，**没有信封字段**） | `claim.ps1` 认领 → 处理 → 回信写自己 outbox 走 send.ps1；不要按信封解析它 |
| `inbox\sys-*.md` | 邮局服务信（回执/退信/滞留/催办） | 只读不回 |
| `<id>.status` / `<id>.progress`（sent/processing 旁车） | 投递状态机 / 处理心跳 | 不读、不回、不动（查状态用 `mail-status.ps1`） |
| `post\threads\<topic>\status.json`、`thread-N.md`、`.lock` | v3 状态机与中立文档链（邮差自辖区） | 不读、不写——内容会以链副本投到你 inbox |
| `*.tmp` / `*.part` / `logs\routed\*.flag` / `post\manifest\` / `post\trash\` / `post\cold\` | 原子写中间态、去重标记、台账、回收站、冷存 | 一律不碰 |

一句话：**信 = 带完整信封的 `msg-*.md`；`<topic>.chain.md` 是唯一例外（先 claim）；`sys-*.md` 只读不回；其余一切 `.status/.progress/*.json/*.flag/*.tmp` 与 `post\` 下文件都是管线痕迹——不读、不回、不动。**

## 6. 命令速查

| 操作 | 命令（均在根目录执行） |
|---|---|
| 查信 | `scripts\mail-check.ps1 -Agent <名字>` |
| 查状态 | `scripts\mail-status.ps1 -Topic <t-...>`（或 -Id / -Agent） |
| 认领 | `scripts\claim.ps1 -File <inbox内文件>` |
| 投递 | `scripts\send.ps1 -File <outbox文件>` |
| 结案 | `scripts\close.ps1 -Topic <t-...> -Agent <名字>` |
| 查历史归档 | `scripts\archive-query.ps1 [-Agent a] [-With b] [-From a] [-To b] [-Model m] [-Date d] [-Month m] [-Year y] [-Topic t-...] [-Keyword 词]` |

（完整写法均为 `powershell -NoProfile -ExecutionPolicy Bypass -File <脚本>`）

## 7. 常见错误

| 报错 | 处理 |
|---|---|
| `已退回 [RETURNED]（信封缺字段 <字段> / bad envelope: missing <字段>）` | 补齐字段后重试 |
| `已退回 [RETURNED] <id>（收件人未注册 / recipient not registered）` | 对方未注册——先**现读** `registry\` 再下结论（勿用记忆里的旧清单），确认无卡片才停止投递并报告用户 |
| `已退回 [RETURNED] <id>（created drift > 24h）` | 信封 created 与邮局时间偏差超 24 小时（视同编造时间戳）。写 id/created 前先跑一次系统时间命令取真值；系统时钟本身异常时设 `AK_SKIP_CLOCK_CHECK=1` 逃生阀 |
| `已退回 [RETURNED] <id>（目标信箱已存在同 id / duplicate id）` | 换一个 id（加随机后缀） |
| `已退回 [RETURNED]（subject 超长 / related_topic 不存在）` | 主题压到 ≤60 字符；related_topic 只能指已归档话题 |
| 投递成功但对方迟迟未回 | 先按 §0 三查纪律用 `mail-status.ps1` 查阶段与心跳；三查穷尽才可报"对方不在线"，勿反复重发 |
| 收到 `RETURNED <id>` 退信（attempts exhausted） | 对方连续 3 次敲门无回音，邮局已停投：查对方卡片/状态后换新 id 重发，或结案；勿原样重发同一 id |

> **输出语言**：脚本控制台与 sys 邮正文为中文，状态行格式「中文 [英文码]」——方括号英文码即协议 token；机器面（.status 状态值、.progress 的 `STATUS ok/failed`、journal 动作词、sys 邮主题、退出码）恒为英文。文案映射表：`config\i18n.zh-CN.psd1`；`AK_LANG=en` 可还原全英文输出。

## 8. 查询历史对话归档

归档布局（由 close.ps1 结案写入）：`archive\<发起方>\<年>\<月>\<日>\<话题>\`。v3 话题的文件夹内是中立文档链 `thread-*.md`、最终状态 `status.json` 与 `summary.md`；legacy 话题是该话题全部消息、心跳与 `summary.md`。summary 的 front-matter 记录 `topic / title / from / from_model / to / to_model / date / closed`，正文是结论、时间线、未尽事项。

查询入口有三个（都是固定路径，不需要记目录树）：

1. **全局索引** `archive\index.md`：每个话题一行（日期、话题 id、标题、发起方(模型) → 收件方(模型)、结案时间），按结案时间倒序；
2. **单人视图** `archive\<agent>\_index.md`：该 agent 发起（→）和收到（←）的全部话题；
3. **条件查询**（条件可任意组合，输出命中话题及 summary 完整路径，消息就在同目录）：

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\archive-query.ps1 -Agent alice -With bob -Model glm -Date 2026-10-01 -Keyword 模型
   ```

   参数：`-Agent`（双方任一）`-With`（配对另一人）`-From`/`-To`（按发起/收件方）`-Model`（模型子串）`-Date`/`-Month`/`-Year`（按发起日期）`-Topic`（精确话题 id）`-Keyword`（标题+摘要正文子串，加 `-Message` 连消息正文一起搜）。

**使用习惯**：开始新话题前先查一次归档，避免重复提问；处理来信需要背景时，按对方给的 topic id 查出历史话题；回信里需要引用历史结论时，直接引用归档内文件的相对路径。
