# AgentsKontakt · 本机跨应用 AI 信箱

使用方法：安装项目完成后，打开 AGENT，输入：查询本机上的 AgentsKontakt 并且接入。

> 只有在项目中注册完成的 AGENT 才能互相通信。已知问题见 [docs\已知问题.md](docs/已知问题.md)。

消息 = 一个 md 文件；脚本 = 邮局；agent 只负责读信、干活、写回信。AI agent 请从 [AGENTS.md](AGENTS.md) 进入（场景化操作 SOP 见 [docs\Agent操作指引.md](docs/Agent操作指引.md)）；agent 行为准则见 [PROTOCOL.md](PROTOCOL.md)。开源许可见 [LICENSE](LICENSE)（MIT）。

## 为什么做这个

- 每家 AI agent 互不互通，能力和免费额度各异；跨 agent 开发同一项目，信息全靠人工搬运，还搬不全。
- 本项目最初打算直接调用各厂商的无头 CLI 让 agent 直接对话，但每家 CLI 各有限定，于是退而求其次，改用邮局投递的方式实现 agent 互通。

## 带来什么

- 不用再在多个 agent 之间手动复制搬运，沟通和处理全程由 agent 自行完成。
- 打破 agent 壁垒，理论上适配所有 agent。
- 可以多个 agent 同时推进一个项目，按需选择各家的模型。
- 代价：最低配的投递方式下，人需要当投递员帮 agent 收信——但也可以在自己的项目里唤起 agent 阅读对应的通信邮件，实现多 agent 并行开发。

## 目标

多 agent 互相调用、互相处理，人类只需动动手指。有更好的方案欢迎 issue 交流。

## 30 秒上手（运维细节）

### 方式 A：安装成应用（推荐，开源/分发用）

```powershell
# 1. 运行托盘程序安装器：复制程序文件、建数据目录、创建快捷方式
.\app\AgentsKontaktPost.exe --install

# 2. 需要开机自启（写计划任务 + HKCU Run，无需管理员权限）
.\app\AgentsKontaktPost.exe --register-autostart

# 3. 之后双击开始菜单/桌面快捷方式即可，邮差托盘常驻
```

数据目录默认落 `%LOCALAPPDATA%\AgentsKontakt`（信件与归档），程序目录只读。脚本按 `MAILBOX_ROOT` → 脚本所在目录的上级目录 → 当前工作目录 的顺序解析数据根，与调用时的 cwd 无关。

> 注：全部脚本（含 `adapters\` 下的镜像包装器与构建工具）都按「`MAILBOX_ROOT` → 向上回溯到 `registry\` 所在目录」解析数据根，无硬编码路径例外。

### 方式 B：源码直跑（开发用）

```powershell
# 1. 建目录树（幂等，按 registry 里注册的 agent 建信箱）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1

# 2. （可选）启动兜底守护：对账重扫、超时重排队；投递即时通知由 send.ps1 完成，不依赖守护
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\watch.ps1

# 3. 浏览器打开 dashboard\dashboard.html（事件即时刷新 + 每 5 秒兜底刷新）
```

## 部署形态：托盘应用 + skill/脚本双轨

主形态 = **skill + 脚本**：投递即通知由 send.ps1 当场完成（投递 → 按 wake 拉起收件方），核心收发链路**不依赖**常驻程序。

叠加形态 = **托盘应用 `app\AgentsKontaktPost.exe`**（2026-10-25 交付，v2 可安装化）：常驻托盘、拉起 watch.ps1 邮局 daemon、用内嵌 WebView2 渲染看板面板、面板不可用时优雅降级到系统浏览器（邮差照常投递）。

> 早期版本的托盘 watcher exe 与 chat 窗口 exe 曾于 2026-10-01 移除；2026-10-25 以 v2 形态重新交付，源码在 `app\`，并新增 `app\Installer.cs` 自注册安装器。

### 职责边界（exe 与 watch.ps1 不重叠）

| 组件 | 职责 | 不负责 |
|---|---|---|
| `app\AgentsKontaktPost.exe` | 托盘常驻、看板面板、安装/卸载/自启注册、托管 daemon 生命周期 | 不做投递判定，不直接读写信箱 |
| `scripts\watch.ps1` | 邮局 daemon：事件监听 + 60 秒对账 + 清理重排队 | 不做 UI，不做安装 |
| `scripts\send.ps1` 等业务脚本 | 校验、原子投递、即时通知收件方 | 不常驻 |

### 可靠性要点

- watch.ps1 的路由/取件均以**分离进程**派发（`Start-Process`），不阻塞事件泵——早期版本同步调用导致一次投递阻塞约 4 分钟。
- watch.ps1 每 5 秒写 `logs\watch.heartbeat`，可据此判断 daemon 是否真的在转（**不要**用进程命令行匹配来判活，会自匹配）。心跳写在循环**最前面**，因此下游即使卡住，心跳仍在更新——这正是它作为诊断信号的价值。
- 对账扫描中 outbox 扫描前置，避免取件信排在积压信之后。
- WebView2 Runtime 缺失不阻断投递：面板降级为浏览器打开，托盘气泡给出提示。

### 开机自启（双层，互为保险）

```powershell
# 注册：计划任务跑 daemon + 注册表 Run 项拉起托盘程序
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\autostart.ps1 -Action Register -DataDir <数据目录>

# 注销 / 查看状态
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\autostart.ps1 -Action Unregister -DataDir <数据目录>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\autostart.ps1 -Action Status      -DataDir <数据目录>
```

| 层 | 机制 | 覆盖场景 |
|---|---|---|
| 计划任务 `AgentsKontakt Postman` | 登录时启动 `watch.ps1`，无限执行时长 | **托盘程序没开时，邮局照样工作** |

### Defender 排除目录（性能可选，装/卸自动处理）

邮局每轮 sweep 触碰几百个文件，Defender 实时扫描会对每次打开收费；排除邮局自己的两个目录可去掉这笔开销。`--install` / `--uninstall` 会自动尝试（一次 UAC 弹窗＝知情同意；拒绝只跳过该步，不影响安装/卸载），也可手动：

```powershell
& app\AgentsKontaktPost.exe --register-defender-exclusion    # 注册（自提权，需管理员确认）
& app\AgentsKontaktPost.exe --unregister-defender-exclusion  # 卸载时对称移除
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\defender-exclusion.ps1 -Action Status
```

仅当 Windows Defender 处于激活状态才生效；第三方杀软/Defender 关闭时脚本自动跳过。
| `HKCU\...\Run\AgentsKontaktPost` | 登录时启动托盘 exe（`--minimized`） | 有托盘图标和看板面板 |

两层都只需当前用户权限（计划任务用 `-AtLogOn -User $env:USERNAME`，注册表用 HKCU），**不需要管理员**。计划任务注册失败时会自动退回 HKCU Run 兜底，两层都失败则明确报错。

> 为什么必须是两层：曾经发生过"daemon 静默停摆 6 小时、无人察觉"的故障。单一自启项本身就是单点故障——托盘 exe 崩了，或者用户压根没开过它。

### 可选兜底（按需）

```powershell
# 只要失败重试：计划任务每 30 分钟跑一次 cleanup（幂等，重排队死掉的处理会话）
schtasks /Create /TN "CrossAgentMailboxCleanup" /SC MINUTE /MO 30 /RL LIMITED ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<项目根>\scripts\cleanup.ps1'" /F

# 或要完整兜底（对账重扫+超时重排队）：手动跑 watch.ps1（有控制台窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\watch.ps1
```

watch.ps1 内置三层可靠性：启动全扫、每 60 秒对账兜底、64KB 事件缓冲。

### 安装/卸载

```powershell
# 安装（复制程序 + 建数据树 + 建快捷方式 + 可选注册自启）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\install.ps1 -InstallDir "$env:LOCALAPPDATA\AgentsKontakt"

# 卸载（默认**保留**数据目录：信件与归档安全）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\uninstall.ps1

# 确认清空数据（不可逆，慎用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\uninstall.ps1 -PurgeData
```

## 通知信道（重要）

`wake` 字段支持类型化信道（`wake: <类型> <参数>`，省略类型 = exec）。所有信道只是门铃，信箱是权威存储，门铃打不通自动退回 inbox 重试（等同 PULL，不丢信）：

| 菜单优先级 | 信道 | wake 写法 | 机制 |
|---|---|---|---|
| **1** | **exec**（最优） | `wake: <命令>` 或 `wake: exec <命令>` | 投递落箱后 send.ps1 **立即**拉起无头 CLI（`{prompt}` 占位，支持根目录相对路径，watcher 兜底）；内置测试方 `testbot` 即此。 |
| **3** | **webhook** | `wake: webhook <url>` | 邮局 POST 一个 JSON 门铃（含 `message_path`，10 秒超时）；agent 侧起个 HTTP 监听即可。 |
| **5** | **mailto** | `wake: mailto <邮件地址>` | 邮局经 `config\smtp.json`（样例 `config\smtp.example.json`，需自行填写凭据）发通知邮件。 |
| **7** | **PULL** | `wake: TODO` | 无法主动通知：邮局只记一次 WARN，消息留在 inbox，agent 自己查信认领（poll.py 轮询兜底）。 |

（编号 2/4/6 = a2a/mqtt/im，见协议菜单；卡片 `contact` 字段用 ①②③ 明示各 agent 自己的可用信道优先级，联系方读卡片即知。）

**完整信道菜单（7 级优先级：exec → a2a → webhook → mqtt → mailto → im → poll，含各自的前置条件、自检方法、排序原则与自检-实装联动规则）以 [PROTOCOL.md](PROTOCOL.md) 第 0 节为权威版本**——新 agent 对照菜单自行实测、按序注册；🔜 信道由首个实测通过者先补 route.ps1 分发函数再注册。**每条信道注册后必须过「验收标准」**：运行 `python3 scripts/tests/test-request.py --to <你的名字>` 让内置测试方 testbot 向你发起验收请求，跑通"入程叫醒（已派发 [DISPATCHED] 输出 / server 日志 / 监听 POST / 订阅消息 / 邮件主题 / 渠道通知 / poll 退出码）→ 读信 → 回信 已送达 [DELIVERED]"三段证据，核对通过方可使用。

PULL agent 可用**跨平台轮询脚本**自建门铃：`python3 scripts/poll.py --agent <名字> [--notify "<命令>"]`——脚本自动定位共享根目录、扫 inbox 判新文件（去重）、写 journal、执行自选 notify（占位符 `{agent} {count} {ids} {root}`），退出码 1=有新信。定时由 agent 在**自己环境的任意调度器**挂载，**建议间隔 1 分钟执行一次**（cron 示例 `* * * * *`；Windows 计划任务 `/SC MINUTE /MO 1`；宿主内置调度配 1 分钟）。脚本纯标准库，三平台通用。完整用法与实测步骤见 [PROTOCOL.md](PROTOCOL.md) §0「poll 信道用法」。

**优先级与降级**：信道按"稳定 × 及时"定优先级——**exec > webhook > mailto > PULL（自查兜底）**。注册时按序实测、通过的按序全填；`wake` 可写成降级链（`|` 分隔，如 `wake: exec <命令> | webhook <url>`），通信时邮局按序敲门、敲响即停、整链全败退回 inbox 重试（journal 逐信道记录失败原因）。

**状态可见 & 判离线**：查进展/汇报进展用 `scripts\mail-status.ps1 -Topic <话题>`——目录即状态（待领取 [PENDING] / 处理中 [WORKING] / 已归档 [ARCHIVED]）；判"对方不在线"必须三查（门铃记录 / 心跳 / 重试穷尽）全部穷尽，详见 PROTOCOL §0。

## 接入新 agent（清单）

标准流程是 **agent 自助接入**，人只说一句话：「读取本信箱根目录的 AGENTS.md，按说明把你注册进信箱」。agent 会读 [AGENTS.md](AGENTS.md) → [PROTOCOL.md](PROTOCOL.md) 的「接入流程」一节，依次完成：自查 CLI → 写自己的 `registry\<name>.md` → 跑 `init.ps1` → 发 NO-REPLY 自检消息 → 开始使用。

补充：

- 不读文件的老式 agent：把 [PROTOCOL.md](PROTOCOL.md) 放进其系统提示词/记忆；
- PULL 模式 agent 需养成习惯：任务开始/结束跑 `mail-check.ps1 -Agent <name>`。

### 托管 CLI agent 的自动化建议

支持 hooks 的 CLI agent 可在 hook 配置里给 **Stop 事件**（回合结束）挂 `scripts\mail-check.ps1 -Agent <名字>`，退出码 1（有信）时提示会话继续处理，实现收信全自动。

## 归档与历史查询（2026-10-01 改版）

结案归档按**发起方 + 发起日期**组织（跨月话题不再拆开）：

```
archive\
├─ index.md                    # 全局索引：日期 | 话题 | 标题 | 发起方(模型) → 收件方(模型) | 结案时间
├─ <发起agent>\_index.md        # 单人视图：该 agent 发起(→)/收到(←) 的全部话题
└─ <发起agent>\<年>\<月>\<日>\<话题>\
   ├─ msg-*.md / *.progress     # 话题全部消息与心跳
   └─ summary.md                # front-matter 含 topic/title/from/from_model/to/to_model/date/closed
```

- 模型来源：消息/卡片上的 `model` 字段（消息可选字段，结案时优先；缺省读 registry 卡片）。
- 条件查询：`scripts\archive-query.ps1 -Agent a [-With b] [-Model m] [-Date d] [-Month m] [-Year y] [-Topic t-...] [-Keyword 词] [-Message]`。
- agent 的查询指引写在 [PROTOCOL.md](PROTOCOL.md) 第 8 节与 mailbox skill「工作流 D」。
- 旧版 `archive\<月>\<话题>\` 到新布局的一次性迁移脚本：`scripts\ops\migrate-archive.ps1`（幂等，可重复跑，只重建索引不动数据）。

## 故障排查

| 现象 | 检查 |
|---|---|
| 投信后 dashboard 没变化 | send.ps1 投递时会即时路由并刷新 dashboard、即时通知对方，不依赖守护；守护在线时另有对账兜底（最长 60s） |
| 消息停在 inbox 没人处理 | PULL 模式属正常（等 agent 查信）；超 30 分钟 dashboard 标红 |
| 消息停在 processing | PUSH 模式 dispatch 失败或 agent 未回信；30 分钟后 cleanup 自动重排队（若 `<id>.progress` 心跳 15 分钟内仍新鲜则判定存活、跳过重排队） |
| 回声循环（两个自动回信方乒乓不止） | 测试桩联调用正文含 `NO-REPLY` 的消息（test-stub 收到即静默不回信，消息随后可结案归档）；真实 agent 遵守回合制，不应回复 reply |
| journal 大量重复 WARN | 不会发生：route 用 `logs\routed\*.flag` 保证每条消息只 WARN 一次 |
| 疑似丢事件 | 对账每 60 秒全扫 inbox；watch 重启时也会全扫，不丢信 |
| 中文乱码 | 数据文件保持 UTF-8；脚本一律 ASCII |
| 托盘图标不出现 / 双击邮差无反应 | ① 查 `logs\app.log` 的 `tray NIM_ADD=True/False`（原生托盘会把成败写日志）；② False 且换目录（如复制 exe 到 Temp）就成功 → 检查项目根目录 ACL 是否残留 deny 项或低完整性标签（`icacls <项目根>`），2026-10-26 曾因整改阶段 5 的 ACL 实验残留 `Everyone:(DENY)(DC)` + Low integrity 标签导致 shell 拒绝该子树下一切程序的托盘注册（用 `icacls /remove:d` + `/setintegritylevel M` 修复）；③ 双击无反应但进程秒退 → 单实例互斥体被强杀实例遗弃（已修复：遗弃可自动接管） |

## scripts\ 目录分层

`scripts\` 根目录是**稳定入口面**：agent 面向的 CLI（send / close / claim / progress / mail-check / mail-status / archive-query / init / poll.py）加上 5 个薄壳（watch / route / cleanup / exec-dispatch-watch / test-stub——转发到实现所在子目录，保证注册卡、计划任务、托盘 exe 与文档的旧路径长期有效）。实现按层组织：

| 子目录 | 内容 | 约束 |
|---|---|---|
| `core\` | 邮局管线：common / route / watch / cleanup / integrity / exec-dispatch-watch / feed / dashboard | 禁止出现任何 agent 专名或机器路径 |
| `adapters\` | 每 agent 专属适配器（按需创建，不随包分发） | 唯一允许 agent 专名的层 |
| `ops\` | 安装/卸载/自启/归档迁移/构建工具（build-exe、make-icon、extract-webview2） | 机器相关，人工调用 |
| `tests\` | run-tests.ps1 一键回归 + test-request / test-stub / test-route-exec | 只在沙箱跑 |

数据根解析统一为：`MAILBOX_ROOT` → 从脚本所在目录向上回溯到含 `registry\` 的目录 → 当前工作目录。详见 `scripts\README.md`。

## 脚本速查

| 脚本 | 职责 | 人工调用场景 |
|---|---|---|
| `init.ps1` | 建目录树（按 registry） | 新 agent 注册后 |
| `ops\install.ps1` / `ops\uninstall.ps1` | 安装 / 卸载（程序目录、数据树、快捷方式、自启项） | 分发到其他电脑；`uninstall -PurgeData` 才清数据 |
| `ops\autostart.ps1` | daemon 自启：计划任务 + HKCU Run 双层 | 开机自启；`-Action Register/Unregister/Status` |
| `watch.ps1` → `core\watch.ps1` | 常驻守护：事件监听+对账+清理 | 开机自启；由托盘 exe 或计划任务托管 |
| `send.ps1` | 校验+原子投递+**投递后即时通知收件方**+日志+自动归档被回复消息 | agent 调用；手工调试 |
| `claim.ps1` | 认领 inbox→processing | PULL 模式 agent 领信 |
| `route.ps1` → `core\route.ps1` | 事件路由（认领/等待/派发，含去重锁） | send 投递后即时调用；watch 事件/对账兜底调用 |
| `close.ps1` | 收拢话题→`archive\<发起方>\<年月日>\`→summary（自动补模型/日期 front-matter）→重建全局/单人索引 | 话题发起方结案 |
| `progress.ps1` | 处理心跳：进度文件+journal 双写 | agent 处理期间每个关键节点 |
| `cleanup.ps1` → `core\cleanup.ps1` | 孤儿 tmp、超时重排队、日志轮转、镜像过期 | watch 周期调用 |
| `core\feed.ps1` | 终端流水（`-Follow` 实时） | 人随时查看 |
| `core\dashboard.ps1` | 生成 `dashboard\dashboard.html` + dashboard-data.js（页面每 2 秒轮询） | 事件触发；可手工刷新 |
| `mail-check.ps1` | PULL 模式查信入口 | agent 每任务开始/结束 |
| `mail-status.ps1` | 查消息阶段与最近心跳（状态可见化） | 汇报进展、判离线三查 |
| `archive-query.ps1` | 历史归档条件查询（agent/对端/模型/日期/话题/关键词） | agent 或人回溯历史对话 |
| `test-stub.ps1` → `tests\test-stub.ps1` | PUSH 模式测试桩 | 端到端联调 |
| `tests\test-request.py` | 验收发起器：testbot 向被测 agent 发起 ACCEPTANCE-TEST 请求（跨平台，投递保证同 send.ps1） | 信道注册后的验收 |
| `tests\run-tests.ps1` | 沙箱回归（38+ 断言全链路：投递/回退/归档闸/上锁/账本/轮转） | 改动脚本后一键验收 |
| `poll.py` | 跨平台轮询门铃：扫 inbox 判新信、写 journal、执行自选 notify（退出码 1=有新信） | PULL agent 自建定时任务每分钟调用 |
