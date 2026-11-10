# build-package.ps1 - one-shot release packaging (v2.2.1+).
#
# Prerequisite: a built app\AgentsKontaktPost.exe (ops\build-exe.ps1).
# Produces in dist\:
#   AgentsKontakt-x64-<ver>.zip        raw payload (parity/AR-7 use)
#   AgentsKontakt-x64-<ver>-Setup.exe  single-file installer, payload embedded
#
# Stage rules: git-tracked files only (deterministic, no local junk), minus
# packaging excludes (vendor, extra registry cards, .gitignore, *.bak), then
# the fresh exe overlaid. Mirrors docs\打包指引.md S4-S6.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\build-package.ps1
#   ... -Version 2.2.1.0   # default: read from the built exe
param(
    [string]$Root = '',
    [string]$Version = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $Root) {
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
    if (-not $d) { throw 'cannot locate project root (no registry\ above script)' }
    $Root = (Resolve-Path -LiteralPath $d).Path
}
$exePath = Join-Path $Root 'app\AgentsKontaktPost.exe'
if (-not (Test-Path -LiteralPath $exePath)) { throw 'app\AgentsKontaktPost.exe missing - run scripts\ops\build-exe.ps1 first' }
if (-not $Version) { $Version = (Get-Item -LiteralPath $exePath).VersionInfo.FileVersion }
$dist = Join-Path $Root 'dist'
$Stage = Join-Path $dist ("stage-AgentsKontakt-x64-" + $Version)
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

# ---- 1. stage = git-tracked files minus packaging excludes ----
# purity requirement (2026-11-03): a deployed tree carries runtime scripts and
# agent-facing docs only - build tooling, tests, requirement/acceptance docs,
# the history log and owner-private wake wrappers stay in the dev tree.
$excludes = @(
    '^vendor/',
    '^\.gitignore$',
    '^dist/',
    '^registry/(?!testbot\.md$)',   # every machine-specific agent card stays out; testbot is system infrastructure
    '\.bak$',
    '^AKRoot.exe$',
    '^scripts/ops/(build-exe|build-package|make-icon|extract-webview2|migrate-archive)\.ps1$',
    '^scripts/tests/(?!test-stub\.ps1$|test-request\.py$)',   # carve-outs: test-stub.ps1 is testbot's runtime body (root shell forwards there); test-request.py is the acceptance initiator every fresh install needs - all agent-facing docs point at scripts\tests\test-request.py as the mandatory gate
    '^scripts/adapters/',
    '^docs/打包指引\.md$',   # build/release doc: dev-tree only, not for deployed trees
    '\.bak-'
)
& git -C $Root ls-files -z | ForEach-Object { $_ -split "`0" } | Where-Object { $_ } | ForEach-Object {
    $gitPath = $_
    foreach ($x in $excludes) { if ($gitPath -match $x) { return } }
    $src = Join-Path $Root $gitPath
    $dst = Join-Path $Stage ($gitPath -replace '/', '\')
    $td  = Split-Path $dst -Parent
    if (-not (Test-Path $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
Copy-Item -LiteralPath $exePath -Destination (Join-Path $Stage 'app\AgentsKontaktPost.exe') -Force

# ---- 1b. staged config must be the clean default: the dev tree's poll_hooks
# ring the dev tree's own agents - a fresh install has no cards for
# them (2026-11-03 purity requirement). Install-time config is copy-if-missing,
# so the shipped file defines the fresh-install default.
$stagedCfg = Join-Path $Stage 'config\system.json'
if (Test-Path -LiteralPath $stagedCfg) {
    $cfg = Get-Content -LiteralPath $stagedCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.PSObject.Properties['poll_hooks']) { $cfg.PSObject.Properties.Remove('poll_hooks') }
    [System.IO.File]::WriteAllText($stagedCfg, ($cfg | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}

# ---- 1c. i18n gate (2026-11-05): the display-text mapping table is runtime
# data - a package without it silently degrades every fresh install to English
# output. Staging is git-tracked-files-only, so an untracked table would slip
# through unnoticed; fail the build instead.
$i18nStage = Join-Path $Stage 'config\i18n.zh-CN.psd1'
if (-not (Test-Path -LiteralPath $i18nStage)) { throw 'i18n gate: config\i18n.zh-CN.psd1 not staged - is it git-tracked? (git add config/i18n.zh-CN.psd1)' }

# ---- 2. human quick-start (UTF-8 BOM) ----
$lines = @(
    'AgentsKontakt 邮差 - 跨应用 AI 信箱（64 位）',
    '================================================',
    '安装：双击 AgentsKontakt-x64-Setup.exe（或解压后运行 scripts\ops\install.ps1）',
    '安装目录：默认 %LOCALAPPDATA%\Programs\AgentsKontakt - 程序与数据同装这一个文件夹：',
    '  app\                                   邮差程序（含 WebView2 组件）',
    '  scripts\                               邮局脚本（运行时唯一副本）',
    '  mailboxes\ registry\ archive\ logs\    信箱、通讯录、归档、日志',
    '  config\                                运行配置与文案映射表（i18n）',
    '  AGENTS.md                              ← AI agent 入口说明（就在本文件夹根目录）',
    '接入你的 AI agent：让它读本文件夹的 AGENTS.md ，按指引自助完成注册与验收。',
    '卸载：开始菜单/桌面「AgentsKontakt 卸载」快捷方式，或 app\AgentsKontaktPost.exe --uninstall',
    '（卸载会把程序和数据一起删除，不保留）'
)
[System.IO.File]::WriteAllText((Join-Path $Stage '安装说明.txt'), (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

# ---- 3. hygiene scan ----
$bad = Get-ChildItem $Stage -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\(mailboxes|archive|logs|post|\.git|\.zcode|vendor|userdata|dashboard)(\\|$)' -or $_.Name -match '^(NUL|debug\.log)$' -or $_.Name -like '*.bak' }
if ($bad) { throw ('hygiene fail: ' + (($bad | Select-Object -First 5 | ForEach-Object FullName) -join '; ')) }

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc not found: $csc" }

# ---- 5b. root launchers (owner requirement): 运行邮差 / 卸载 at package root
$launcherSrc = Join-Path $Root 'app\Launcher.cs'
$ltext = [System.IO.File]::ReadAllText($launcherSrc, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($launcherSrc, $ltext, (New-Object System.Text.UTF8Encoding($true)))
$runExe = Join-Path $Stage '运行邮差.exe'
$unExe  = Join-Path $Stage '卸载.exe'
& $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$runExe" "/win32icon:$(Join-Path $Root 'app\post.ico')" /r:System.dll /r:System.Windows.Forms.dll (Join-Path $Root 'app\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'launcher (run) csc failed' }
& $csc /nologo /target:winexe /platform:x64 /optimize+ /define:UNINSTALL "/out:$unExe" "/win32icon:$(Join-Path $Root 'app\post.ico')" /r:System.dll /r:System.Windows.Forms.dll (Join-Path $Root 'app\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'launcher (uninstall) csc failed' }

# ---- 4. payload zip ----
$zip = Join-Path $dist ("AgentsKontakt-x64-" + $Version + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $zip -Force

# ---- 5. Setup exe (payload embedded as resource) ----
# Setup.cs carries Chinese UI strings: must be UTF-8 BOM before the in-box
# csc sees it (BOM-less = GBK assumption = mojibake), same rule as build-exe.
$setupSrc = Join-Path $Root 'app\Setup.cs'
$text = [System.IO.File]::ReadAllText($setupSrc, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($setupSrc, $text, (New-Object System.Text.UTF8Encoding($true)))
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc not found: $csc" }
$setupExe = Join-Path $dist ("AgentsKontakt-x64-" + $Version + "-Setup.exe")
& $csc /nologo /target:winexe /platform:x64 /optimize+ `
    "/out:$setupExe" `
    "/win32icon:$(Join-Path $Root 'app\post.ico')" `
    "/res:$(Join-Path $dist ("AgentsKontakt-x64-" + $Version + ".zip")),payload.zip" `
    /r:System.dll /r:System.Core.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
    /r:System.Drawing.dll /r:System.Windows.Forms.dll `
    (Join-Path $Root 'app\Setup.cs') (Join-Path $Root 'app\AssemblyInfo.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

$f2 = @(Get-ChildItem $Stage -Recurse -File)
Write-Host ("payload zip: {0} KB ({1} files staged)" -f [math]::Round((Get-Item $zip).Length/1KB), $f2.Count)
Write-Host ("setup exe  : {0} KB  version {1}" -f [math]::Round((Get-Item $setupExe).Length/1KB), (Get-Item $setupExe).VersionInfo.FileVersion)
Write-Host ("dist ready : " + $dist)
