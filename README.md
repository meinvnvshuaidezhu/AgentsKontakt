# AgentsKontakt · 本机跨应用 AI 信箱（文档大部分是AI写的，看重点接入新agent就可以了。）

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

### 安装（以当前 Releases 安装包为准）

从 [Releases](https://github.com/meinvnvshuaidezhu/AgentsKontakt/releases) 下载当前版本 `AgentsKontakt-x64-<版本>-Setup.exe`，双击运行安装向导：

- 默认安装目录 `%LOCALAPPDATA%\Programs\AgentsKontakt`，**安装目录本身即数据根**（扁平布局：程序与信箱数据同目录，日后整体可搬迁）
- 安装过程自动完成：信箱目录树初始化、开始菜单/桌面快捷方式、标准卸载入口（设置→应用可见）、Defender 排除目录注册（一次 UAC，拒绝不影响安装）
- 完成后双击快捷方式启动，邮差托盘常驻；开机自启（可选，无需管理员）：`& <安装目录>\app\AgentsKontaktPost.exe --register-autostart`

静默安装（运维/批量部署）：

```powershell
# 默认目录
AgentsKontakt-x64-2.4.2.0-Setup.exe --silent
# 自定义安装目录；跳过 Defender 排除；跳过快捷方式
AgentsKontakt-x64-2.4.2.0-Setup.exe --silent --install-dir D:\Software\AgentsKontakt --no-defender --no-shortcuts
# 数据目录与安装目录分离（默认不分离：数据根=安装目录）
AgentsKontakt-x64-2.4.2.0-Setup.exe --silent --data-dir D:\AgentsKontaktData
```

便携（免安装）：下载同版 `AgentsKontakt-x64-<版本>.zip`，解压到任意可写目录，运行 `app\AgentsKontaktPost.exe`。数据根解析顺序：`MAILBOX_ROOT` → 脚本所在目录的上级目录 → 当前工作目录，与调用时 cwd 无关。

卸载：设置→应用→AgentsKontakt（安装器注册的标准入口），或 `& <安装目录>\app\AgentsKontaktPost.exe --uninstall`（默认保留数据目录）。

开发直跑（源码树）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\watch.ps1   # 可选：兜底守护
```

## 接入新 agent（清单）

标准流程是 **agent 自助接入**，人只说一句话：「搜索本机安装的AgentsKontakt应用，读取根目录的 AGENTS.md，按说明把你注册进信箱」。agent 会读 [AGENTS.md](AGENTS.md) → [PROTOCOL.md](PROTOCOL.md) 的「接入流程」一节，依次完成：自查 CLI → 写自己的 `registry\<name>.md` → 跑 `init.ps1` → 发 NO-REPLY 自检消息 → 开始使用。

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
├─ index.jsonl                 # v3 追加式归档索引（archive-query 无 Model/Keyword 条件时的快查后端）
├─ <发起agent>\_index.md        # 单人视图：该 agent 发起(→)/收到(←) 的全部话题
└─ <发起agent>\<年>\<月>\<日>\<话题>\
   ├─ v3 话题：thread-*.md（中立文档链）+ status.json（最终状态）+ summary.md
   ├─ legacy 话题：msg-*.md / *.progress（话题全部消息与心跳）+ summary.md
   └─ summary.md front-matter 含 topic/title/from/from_model/to/to_model/date/closed
```

- 模型来源：消息/卡片上的 `model` 字段（消息可选字段，结案时优先；缺省读 registry 卡片）。
- 条件查询：`scripts\archive-query.ps1 -Agent a [-With b] [-Model m] [-Date d] [-Month m] [-Year y] [-Topic t-...] [-Keyword 词] [-Message]`。
- agent 的查询指引写在 [PROTOCOL.md](PROTOCOL.md) 第 8 节与 mailbox skill「工作流 D」。
- 旧版 `archive\<月>\<话题>\` 到新布局的一次性迁移脚本：`scripts\ops\migrate-archive.ps1`（幂等，可重复跑，只重建索引不动数据）。

## 故障排查

| 现象 | 检查 |
|---|---|
| 投信后 dashboard 没变化 | send.ps1 投递时会即时路由并刷新 dashboard、即时通知对方，不依赖守护；守护在线时另有对账兜底（有信活动 120s / 空闲 300s 一轮） |
| 消息停在 inbox 没人处理 | PULL 模式属正常（等 agent 查信）；超 30 分钟 dashboard 标红 |
| 消息停在 processing | PUSH 模式 dispatch 失败或 agent 未回信；30 分钟后 cleanup 自动重排队（若 `<id>.progress` 心跳 15 分钟内仍新鲜则判定存活、跳过重排队） |
| 回声循环（两个自动回信方乒乓不止） | 测试桩联调用正文含 `NO-REPLY` 的消息（test-stub 收到即静默不回信，消息随后可结案归档）；真实 agent 遵守回合制，不应回复 reply |
| journal 大量重复 WARN | 不会发生：route 用 `logs\routed\*.flag` 保证每条消息只 WARN 一次 |
| 疑似丢事件 | 对账全扫 inbox（有信活动 120s / 空闲 300s 一轮）；watch 重启时也会全扫，不丢信 |
| 中文乱码 | 数据文件保持 UTF-8；脚本一律 ASCII |
| 托盘图标不出现 / 双击邮差无反应 | ① 查 `logs\app.log` 的 `tray NIM_ADD=True/False`（原生托盘会把成败写日志）；② False 且换目录（如复制 exe 到 Temp）就成功 → 检查项目根目录 ACL 是否残留 deny 项或低完整性标签（`icacls <项目根>`），2026-10-26 曾因整改阶段 5 的 ACL 实验残留 `Everyone:(DENY)(DC)` + Low integrity 标签导致 shell 拒绝该子树下一切程序的托盘注册（用 `icacls /remove:d` + `/setintegritylevel M` 修复）；③ 双击无反应但进程秒退 → 单实例互斥体被强杀实例遗弃（已修复：遗弃可自动接管） |

## scripts\ 目录分层

`scripts\` 根目录是**稳定入口面**：agent 面向的 CLI（send / close / claim / progress / mail-check / mail-status / archive-query / init / poll.py，另有实现真身 `archive.ps1`、`orphan-scan.ps1` 也在根层）加上 5 个薄壳（watch / route / cleanup / exec-dispatch-watch / test-stub——转发到实现所在子目录，保证注册卡、计划任务、托盘 exe 与文档的旧路径长期有效）。实现按层组织：

| 子目录 | 内容 | 约束 |
|---|---|---|
| `core\` | 邮局管线：common / i18n / route / watch / cleanup / integrity / exec-dispatch-watch / feed / dashboard / threads | 禁止出现任何 agent 专名或机器路径（唯一既存例外：`core\dashboard.ps1` 的看板视图中心 `'zcode'`，历史决定，新代码不得新增） |
| `adapters\` | 每 agent 专属适配器（按需创建，不随包分发） | 唯一允许 agent 专名的层 |
| `ops\` | 安装/卸载/自启/Defender 排除/归档迁移/UTF-8 BOM 迁移/索引回填/打包与构建工具 | 机器相关，人工调用 |
| `tests\` | run-tests.ps1 一键回归 + test-request / test-stub / test-route-exec / test-deadletter / test-wrapper-integrity / test-v3-orphan / test-v3-selftest | 只在沙箱跑 |

数据根解析统一为：`MAILBOX_ROOT` → 从脚本所在目录向上回溯到含 `registry\` 的目录 → 当前工作目录。详见 `scripts\README.md`。

## 脚本速查

| 脚本 | 职责 | 人工调用场景 |
|---|---|---|
| `init.ps1` | 建目录树（按 registry） | 新 agent 注册后 |
| `ops\install.ps1` / `ops\uninstall.ps1` | 安装 / 卸载（程序目录、数据树、快捷方式、自启项） | 分发到其他电脑；卸载会连同数据目录一起删除（无保留选项） |
| `ops\autostart.ps1` | daemon 自启：计划任务 + HKCU Run 双层 | 开机自启；`-Action Register/Unregister/Status` |
| `watch.ps1` → `core\watch.ps1` | 常驻守护：事件监听+对账+清理 | 开机自启；由托盘 exe 或计划任务托管 |
| `send.ps1` | 校验+原子投递+**投递后即时通知收件方**+日志+回信送达时把对方在途正本标记为已回信 [REPLIED]（归档只在结案/超时自动归档时发生） | agent 调用；手工调试 |
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
