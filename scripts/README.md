# scripts\ — 目录分层与规则

> `scripts\` 根目录是**稳定入口面**：改这里之前先读完本页。
> 数据根解析（所有脚本统一）：① 环境变量 `MAILBOX_ROOT` → ② 从脚本所在目录**向上回溯**到含 `registry\` 的目录 → ③ 当前工作目录。与调用时的 cwd 无关。

## 布局

```
scripts\
├─ *.ps1 / poll.py            # 根层 = agent 面向的 CLI + 薄壳（见下）
├─ core\                      # 邮局管线实现（零 agent 特例）
│   common.ps1  i18n.ps1  route.ps1  watch.ps1  cleanup.ps1  integrity.ps1
│   exec-dispatch-watch.ps1  feed.ps1  dashboard.ps1
├─ adapters\                  # 每 agent 适配器（唯一允许 agent 专名的层；按需创建）
│   <agent>-wake.ps1  <agent>-mirror.py
├─ ops\                       # 机器相关、人工调用
│   install.ps1  uninstall.ps1  autostart.ps1  migrate-archive.ps1
│   build-exe.ps1  make-icon.ps1  extract-webview2.ps1
└─ tests\                     # 只在沙箱跑
    run-tests.ps1  test-request.py  test-stub.ps1  test-route-exec.ps1
    test-deadletter.ps1  test-wrapper-integrity.ps1   # 后者：静态源码体检（控制字节 + Join-Path 目标解析），防转义层吃反斜杠复发
```

> **文案层（2026-11-05 起）**：面向 agent/用户的控制台与 sys 邮正文文案统一经 `core\i18n.ps1` 的映射函数（`Get-AkText` / `Get-AkLines` / `Get-AkStatusName`）输出，文案本体在 `config\i18n.<lang>.psd1`（默认 `zh-CN`；`AK_LANG=en` 还原英文）——**改文案只改映射表，不动脚本**。机器面恒为英文：.status 状态值、.progress 的 `STATUS ok/failed` 与 `DISPATCHED (post office…)` 协议行、journal 动作词、sys 邮主题、退出码。含中文的数据文件必须 UTF-8 BOM。

## 根层两类文件

1. **agent CLI（真身）**：`send.ps1` `close.ps1` `claim.ps1` `progress.ps1`
   `mail-check.ps1` `mail-status.ps1` `archive-query.ps1` `init.ps1` `poll.py` ——
   这是 AGENTS.md / PROTOCOL.md / registry 卡片里公开文档化的命令面，**移动前必须同步全部文档与各方习惯**。
2. **薄壳（stub，转发器）**：`watch.ps1` `route.ps1` `cleanup.ps1`
   `exec-dispatch-watch.ps1` `test-stub.ps1` ——
   各 5 行，转发到实现所在子目录。存在的理由：这些路径被**不属于本仓库管理的文件**引用——
   registry 卡片的 wake 字段（testbot）、计划任务与 HKCU Run、托盘 exe 的源码路径、
   以及各 agent 会话里已形成的肌肉记忆。**薄壳是永久设施，不是过渡品**；删除前先确认
   上述引用方全部迁移完毕。

## 三条硬规则

1. **`core\` 内禁止 agent 专名与机器绝对路径**——core 只认 registry 卡片与数据根；
   per-agent 特例一律进 `adapters\`。
2. **新脚本按职责入层**：邮局管线 → `core\`；某 agent 专属 → `adapters\`；
   部署运维 → `ops\`；验证 → `tests\`。不再往根层加真身文件。
3. **改完脚本跑回归**：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\run-tests.ps1`
   （沙箱全链路，约 1 分钟，退出码 0 = 全绿）。托盘 exe 改动后重建：
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\build-exe.ps1`。
4. **文案走映射表（2026-11-05 起）**：所有面向 agent/用户的控制台与 sys 邮正文文案，必须经 `core\i18n.ps1` 的
   `Get-AkText` / `Get-AkLines` / `Get-AkStatusName` 查表输出——调用点写英文原文作兜底，中文（及其他语言）只写在
   `config\i18n.<lang>.psd1`；**改文案只改映射表，不动脚本**。机器面（.status 状态值、.progress 协议行、
   journal 动作词、sys 邮主题、退出码）恒为英文；含中文的数据文件必须 UTF-8 BOM。

## 生成物位置

看板生成物在 `<根>\dashboard\`（dashboard.html + dashboard-data.js），由
`core\dashboard.ps1` 在每次投递事件后重写；日志在 `<根>\logs\`（journal 超
`config\system.json` 的 `rotate_size_mb` 自动轮转，会话镜像转录超
`stream_retention_days` 自动过期）。两者都不入 git（见根 `.gitignore`）。
