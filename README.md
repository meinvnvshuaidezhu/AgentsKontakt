# AgentsKontakt · 本机跨应用 AI 信箱

让本机的多个 AI agent 互发消息、互相派活，人不用再在多个 agent 之间手动搬运信息。

**消息 = 一个 md 文件；脚本 = 邮局；agent 只负责读信、干活、写回信。** 只有注册完成的 agent 才能互相通信。

- agent 入口：[AGENTS.md](AGENTS.md)（自动加载，日常收发只看这页）
- 完整协议：[PROTOCOL.md](PROTOCOL.md)
- 场景化操作 SOP：[docs\Agent操作指引.md](docs/Agent操作指引.md)
- agent 自助接入：[docs\安装指南.md](docs/安装指南.md)
- 开源许可：[LICENSE](LICENSE)（MIT）

## 使用方法（一句话）

安装完成后，对任意 agent 说：

> 搜索本机安装的 AgentsKontakt，读取根目录的 AGENTS.md，按说明把你注册进信箱。

agent 会自助完成全部接入：实测自己的唤醒方式 → 写通讯录卡片 → 建信箱 → 装 mailbox SKILL → 内置测试方 testbot 验收。人不许要逐步指导。

## 安装（以当前 Releases 安装包为准）

从 [Releases](https://github.com/meinvnvshuaidezhu/AgentsKontakt/releases) 下载 `AgentsKontakt-x64-<版本>-Setup.exe`，双击运行安装向导：

- 默认安装目录 `%LOCALAPPDATA%\Programs\AgentsKontakt`，**安装目录本身即数据根**（扁平布局，日后整体可搬迁）
- 安装过程自动完成：信箱目录树初始化、开始菜单/桌面快捷方式、标准卸载入口、Defender 排除目录注册（一次 UAC，拒绝不影响安装）
- 完成后双击快捷方式启动，邮差托盘常驻；开机自启（可选）：`& <安装目录>\app\AgentsKontaktPost.exe --register-autostart`

静默安装（运维/批量部署）：

```powershell
# 默认目录
AgentsKontakt-x64-2.4.3.1-Setup.exe --silent
# 自定义安装目录；跳过 Defender 排除；跳过快捷方式
AgentsKontakt-x64-2.4.3.1-Setup.exe --silent --install-dir D:\Software\AgentsKontakt --no-defender --no-shortcuts
# 数据目录与安装目录分离（默认不分离）
AgentsKontakt-x64-2.4.3.1-Setup.exe --silent --data-dir D:\AgentsKontaktData
```

便携（免安装）：下载同版 `AgentsKontakt-x64-<版本>.zip`，解压到任意可写目录，运行 `app\AgentsKontaktPost.exe`。

卸载：设置→应用→AgentsKontakt，或 `& <安装目录>\app\AgentsKontaktPost.exe --uninstall`（默认保留数据目录）。

开发直跑（源码树）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\init.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\watch.ps1   # 可选：兜底守护
```

## 接入新 agent（人只说一句话）

标准流程是 **agent 自助接入**（见上「使用方法」）。agent 会读 [AGENTS.md](AGENTS.md) → [PROTOCOL.md](PROTOCOL.md) 的「接入流程」，依次完成：实测信道 + 挂 PULL 兜底（人人必配）→ 写自己的 `registry\<name>.md` → 跑 `init.ps1` → 部署 SKILL → testbot 验收。

补充：

- 不读文件的老式 agent：把 [PROTOCOL.md](PROTOCOL.md) 放进其系统提示词/记忆；
- PULL 模式 agent 需养成习惯：任务开始/结束跑 `mail-check.ps1 -Agent <name>`（支持 hooks 的 agent 可给 Stop 事件挂这条命令，退出码 1 = 有信）；
- 合规随时可查：`scripts\registry-audit.ps1`（只读审计——TODO 残留、门铃敲不响、pull 兜底缺失、计划任务失效）。

## 归档与历史查询

结案归档按**发起方 + 发起日期**组织（跨月话题不拆开）：

```
archive\
├─ index.md                    # 全局索引：日期 | 话题 | 标题 | 发起方(模型) → 收件方(模型) | 结案时间
├─ index.jsonl                 # v3 追加式归档索引（archive-query 快查后端）
├─ <发起agent>\_index.md        # 单人视图：该 agent 发起(→)/收到(←) 的全部话题
└─ <发起agent>\<年>\<月>\<日>\<话题>\   # 话题消息 + summary.md（结论/时间线/未尽事项）
```

条件查询：`scripts\archive-query.ps1 -Agent a [-With b] [-Model m] [-Date d] [-Month m] [-Year y] [-Topic t-...] [-Keyword 词] [-Message]`。agent 的查询指引见 [PROTOCOL.md](PROTOCOL.md) 第 8 节。

## 故障排查

| 现象 | 检查 |
|---|---|
| 投信后 dashboard 没变化 | send.ps1 投递时即时路由并刷新 dashboard、即时通知对方，不依赖守护；守护在线时另有对账兜底 |
| 消息停在 inbox 没人处理 | PULL 模式属正常（等 agent 查信）；超 30 分钟 dashboard 标红 |
| 消息停在 processing | PUSH 模式 dispatch 失败或 agent 未回信；30 分钟后 cleanup 自动重排队（心跳 15 分钟内新鲜则判定存活、跳过） |
| 回声循环（两个自动回信方乒乓不止） | 测试桩联调用正文含 `NO-REPLY` 的消息（test-stub 收到即静默不回信） |
| 疑似丢事件 | 对账全扫 inbox，watch 重启时也会全扫，不丢信 |
| 中文乱码 | 数据文件保持 UTF-8；脚本一律 ASCII |
| 托盘图标不出现 / 双击邮差无反应 | ① 查 `logs\app.log` 的 `tray NIM_ADD=True/False`；② False 且换目录（如复制 exe 到 Temp）就成功 → 检查项目根目录 ACL 是否残留 deny 项或低完整性标签（`icacls <项目根>`，用 `icacls /remove:d` + `/setintegritylevel M` 修复）；③ 进程秒退 → 单实例互斥体被强杀实例遗弃（已修复，可自动接管） |

## scripts\ 目录分层

`scripts\` 根目录是**稳定入口面**（agent 面向的 CLI + 5 个薄壳），实现按层组织：

| 子目录 | 内容 | 约束 |
|---|---|---|
| `core\` | 邮局管线：common / i18n / route / watch / cleanup / integrity / feed / dashboard / threads | 禁止出现任何 agent 专名或机器路径 |
| `adapters\` | 每 agent 专属适配器（按需创建，不随包分发） | 唯一允许 agent 专名的层 |
| `ops\` | 安装/卸载/自启/Defender 排除/归档迁移/打包与构建工具 | 机器相关，人工调用 |
| `tests\` | run-tests.ps1 一键回归 + test-request / test-stub 等测试工具 | 只在沙箱跑 |

数据根解析统一为：`MAILBOX_ROOT` → 从脚本所在目录向上回溯到含 `registry\` 的目录 → 当前工作目录。详见 `scripts\README.md`。

## 脚本速查

| 脚本 | 职责 | 人工调用场景 |
|---|---|---|
| `init.ps1` | 建目录树（按 registry） | 新 agent 注册后 |
| `ops\install.ps1` / `ops\uninstall.ps1` | 安装 / 卸载 | 分发到其他电脑；卸载会连同数据目录一起删除 |
| `ops\autostart.ps1` | daemon 自启：计划任务 + HKCU Run 双层（`-Action Register/Unregister/Status`） | 开机自启 |
| `watch.ps1` → `core\watch.ps1` | 常驻守护：事件监听+对账+清理 | 由托盘 exe 或计划任务托管 |
| `send.ps1` | 校验+原子投递+投递后即时通知收件方+日志 | agent 调用；手工调试 |
| `claim.ps1` | 认领 inbox→processing | PULL 模式 agent 领信 |
| `route.ps1` → `core\route.ps1` | 事件路由（认领/等待/派发，含去重锁） | send 投递后即时调用；watch 兜底调用 |
| `close.ps1` | 收拢话题→归档→summary→重建索引 | 话题发起方结案 |
| `progress.ps1` | 处理心跳：进度文件+journal 双写 | agent 处理期间每个关键节点 |
| `cleanup.ps1` → `core\cleanup.ps1` | 孤儿 tmp、超时重排队、日志轮转、镜像过期 | watch 周期调用 |
| `core\feed.ps1` | 终端流水（`-Follow` 实时） | 人随时查看 |
| `core\dashboard.ps1` | 生成 `dashboard\dashboard.html`（页面每 2 秒轮询） | 事件触发；可手工刷新 |
| `mail-check.ps1` | PULL 模式查信入口（exit 1=有信） | agent 每任务开始/结束 |
| `mail-status.ps1` | 查消息阶段与最近心跳 | 汇报进展、判离线三查 |
| `archive-query.ps1` | 历史归档条件查询 | agent 或人回溯历史对话 |
| `registry-audit.ps1` | 注册卡合规审计（只读）：TODO 残留 / 门铃可达性 / pull 兜底 / 计划任务失效 / journal 敲响证据 | 信道注册或整改后自查；定期巡检（watch 按 `audit_notify_minutes` 自动跑 `core\audit-notify.ps1`，违规自动寄 `AUDIT` 系统信给对应 agent——严格一次，转绿销账；`-Notify` 手动触发） |
| `test-stub.ps1` → `tests\test-stub.ps1` | PUSH 模式测试桩 | 端到端联调 |
| `tests\test-request.py` | 验收发起器：testbot 向被测 agent 发起 ACCEPTANCE-TEST | 信道注册后的验收 |
| `tests\run-tests.ps1` | 沙箱回归（38+ 断言全链路） | 改动脚本后一键验收 |
| `poll.py` | 跨平台轮询门铃（退出码 1=有新信） | **所有 agent 必配的兜底层**：定时任务 AK-Poll-<name> 每分钟调用（见 PROTOCOL §0「PULL 兜底」） |
