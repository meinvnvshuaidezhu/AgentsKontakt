param(
    # Where the program files land (code only; may be read-only).
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\AgentsKontakt",
    # Where the mailbox data lands (must be writable).
    [string]$DataDir = '',   # default: <InstallDir>\data\ (one folder for everything)
    # Source tree to copy from. Empty = the tree this script lives in.
    [string]$SourceRoot = '',
    # Register a login autostart entry.
    [switch]$WithAutostart,
    # Skip the autostart registration (default when running unattended).
    [switch]$NoAutostart,
    # Skip the Defender exclusion attempt (unattended installs; the interactive
    # default pops one UAC prompt and a declined prompt just skips the step).
    [switch]$NoDefenderExclusion,
    # Skip Start Menu / desktop shortcut creation (v2.3.2).
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
# normalize: callers may pass mixed-slash paths; the defender -Root quoting and
# every literal match below assume backslash form
$InstallDir = $InstallDir -replace '/', '\'
$DataDir = $DataDir -replace '/', '\'

if (-not $SourceRoot) {
    # scripts\ops\install.ps1 -> the project root is up where registry\ lives.
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
    if ($d) { $SourceRoot = $d } else { $SourceRoot = Split-Path $PSScriptRoot -Parent }
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path

# data dir default (2026-11-03): the install dir ITSELF is the mailbox root -
# flat portable layout, code and data side by side, agent docs at the folder
# root. An explicit -DataDir still wins (separated layouts keep working).
if (-not $DataDir) { $DataDir = $InstallDir }
# flat layout: data dir == install dir (one folder, everything inside).
$flat = [string]::Equals($DataDir.TrimEnd('\'), $InstallDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
# when the source tree IS the data dir (dev self-install) the data-layer
# staging below would copy folders onto themselves - guarded per section.
$selfData = [string]::Equals($SourceRoot.TrimEnd('\'), $DataDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)

$exeSrc = Join-Path $SourceRoot 'app\AgentsKontaktPost.exe'
if (-not (Test-Path -LiteralPath $exeSrc)) {
    throw "source tree incomplete - no exe at: $exeSrc"
}

Write-Host '=============================================================='
Write-Host ' AgentsKontakt Postman - installer'
Write-Host '=============================================================='
Write-Host ("  version   : {0}" -f (Get-Item -LiteralPath $exeSrc).VersionInfo.FileVersion)
Write-Host ("  source   : {0}" -f $SourceRoot)
Write-Host ("  install  : {0}" -f $InstallDir)
Write-Host ("  data     : {0}" -f $DataDir)
Write-Host ''

# ---------------------------------------------------------------- 1. copy code
$sameTree = ([string]::Equals($SourceRoot.TrimEnd('\'), $InstallDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase))
if ($sameTree) {
    Write-Host '  [--] source == install: code copy skipped'
} else {
    # flat layout: scripts/templates/assets/config are staged by the data
    # layer below into the same folder - only app\ needs a code copy here
    $codeDirs = if ($flat) { @('app') } else { @('app', 'scripts', 'templates', 'assets', 'config') }
    foreach ($d in $codeDirs) {
        $src = Join-Path $SourceRoot $d
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $InstallDir $d
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("  [ok] copied {0}" -f $d)
    }
}
# WebView2 runtime bits travel with the app so it works on a fresh machine.
foreach ($f in @('Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll','WebView2Loader.dll','post.ico')) {
    $src = Join-Path $SourceRoot ('app\' + $f)
    if (Test-Path -LiteralPath $src) {
        $dstDir = Join-Path $InstallDir 'app'
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dstDir -Force
    }
}
Write-Host '  [ok] webview2 assemblies'

# ---------------------------------------------------------------- 2. data tree
$dataDirs = @('mailboxes','registry','archive','logs','logs\routed','post\manifest','post\cold','templates','config')
foreach ($d in $dataDirs) {
    $p = Join-Path $DataDir $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
Write-Host ("  [ok] data tree ready: {0}" -f $DataDir)

# Templates/assets are copied into the data dir too (force-refresh: they are
# templates, not user data). config is DIFFERENT: system.json carries user
# tuning - an upgrade must never clobber it (v2.2, packaging guide S3b), so
# config files are copied only when missing on the target.
foreach ($d in @('templates','assets')) {
    if ($selfData) { break }   # source == target: nothing to stage
    $src = Join-Path $SourceRoot $d
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $DataDir $d
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
}
$cfgSrc = Join-Path $SourceRoot 'config'
if ($selfData) { $cfgSrc = '' }   # source == target: nothing to stage
if (Test-Path -LiteralPath $cfgSrc) {
    $cfgDst = Join-Path $DataDir 'config'
    if (-not (Test-Path -LiteralPath $cfgDst)) { New-Item -ItemType Directory -Path $cfgDst -Force | Out-Null }
    foreach ($f in (Get-ChildItem -LiteralPath $cfgSrc -Recurse -File)) {
        # guard: $cfgSrc may arrive as an 8.3 short path while FileInfo carries
        # the long form - prefix-substring would then shred the relative path.
        # Fall back to a flat copy by file name (config is flat today).
        $rel = if ($f.FullName.StartsWith($cfgSrc, [System.StringComparison]::OrdinalIgnoreCase)) {
            $f.FullName.Substring($cfgSrc.Length).TrimStart('\')
        } else { $f.Name }
        $target = Join-Path $cfgDst $rel
        if (-not (Test-Path -LiteralPath $target)) {
            $tdir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        }
    }
}
# The scripts must live in the data dir as well: MAILBOX_ROOT resolution means
# the daemon runs "<dataDir>\scripts\watch.ps1" and every nested call resolves
# against the same root. Runtime-only filter (2026-11-03 purity requirement):
# build scripts, tests and owner-private wake wrappers never reach a deploy.
$scriptsDst = Join-Path $DataDir 'scripts'
if (-not (Test-Path -LiteralPath $scriptsDst)) { New-Item -ItemType Directory -Path $scriptsDst -Force | Out-Null }
if ($selfData) {
    Write-Host '  [--] source == data dir: scripts staging skipped'
} else {
    $scriptsSrc = Join-Path $SourceRoot 'scripts'
    # match on forward-slash-normalized rel paths; tests\test-stub.ps1 is
    # testbot's runtime body and must deploy despite the tests\ skip
    # (2026-11-04 carve-out, mirrors build-package.ps1's exclude).
    $devOnly = '^(ops/(build-exe|build-package|make-icon|extract-webview2|migrate-archive)\.ps1|tests/(?!test-stub\.ps1$)|adapters/)'
    foreach ($f in (Get-ChildItem -LiteralPath $scriptsSrc -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($scriptsSrc.Length + 1).Replace('\', '/')
        if ($rel -match $devOnly) { continue }
        $dst = Join-Path $scriptsDst $rel
        $td = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  [ok] scripts staged into data dir'
}

# ---- 2b. doc layer (v2.2): the entry documents must be discoverable at the
# folder ROOT - a cold agent pointed at the install reads AGENTS.md right
# where it lands (2026-11-03: flat layout, root == data root).
if ($selfData) {
    Write-Host '  [--] source == data dir: doc staging skipped'
} else {
    foreach ($doc in @('AGENTS.md','PROTOCOL.md','README.md')) {
        $src = Join-Path $SourceRoot $doc
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $DataDir -Force }
    }
    foreach ($d in @('docs','skills')) {
        $src = Join-Path $SourceRoot $d
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $DataDir $d
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        if ($d -eq 'docs') {
            # runtime docs only - requirement/acceptance/build docs and the
            # history log stay in the dev tree (2026-11-03 purity requirement)
            $devDocs = @('单机多agent需求.md','多机互联需求.md','安装向导需求与验收.md','安装版验收测试需求.md','打包指引.md')
            foreach ($f in (Get-ChildItem -LiteralPath $src -File)) {
                if ($devDocs -contains $f.Name) { continue }
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            }
        } else {
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host '  [ok] doc layer staged into data dir'
}

# ---- 2c. root launchers (v2.2.4): 运行邮差 / 卸载 at the program root
foreach ($f in @('运行邮差.exe','卸载.exe')) {
    $lsrc = Join-Path $SourceRoot $f
    if (Test-Path -LiteralPath $lsrc) { Copy-Item -LiteralPath $lsrc -Destination (Join-Path $InstallDir $f) -Force }
}

# ---------------------------------------------------------------- 3. registry cards
$regSrc = Join-Path $SourceRoot 'registry'
$regDst = Join-Path $DataDir 'registry'
if (-not (Test-Path -LiteralPath $regDst)) { New-Item -ItemType Directory -Path $regDst -Force | Out-Null }
if (Test-Path -LiteralPath $regSrc) {
    Copy-Item -Path (Join-Path $regSrc '*.md') -Destination $regDst -Force -ErrorAction SilentlyContinue
    $n = @(Get-ChildItem $regDst -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    Write-Host ("  [ok] registry cards staged: {0}" -f $n)
}

# ---------------------------------------------------------------- 4. shortcuts
# Created here rather than in the C# installer: WScript.Shell late binding
# from .NET fails to save .lnk files on this platform, while PowerShell's COM
# call works. The shortcut name contains Chinese characters, so this file
# MUST keep its UTF-8 BOM - PowerShell 5.1 reads BOM-less files as GBK and
# the name would come out as mojibake.
$exe = Join-Path $InstallDir 'app\AgentsKontaktPost.exe'
if (-not (Test-Path -LiteralPath $exe)) { $exe = $exeSrc }
if (-not $NoShortcuts) {
$startMenu = [Environment]::GetFolderPath('StartMenu')
$desktop = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
foreach ($dir in @($startMenu, $desktop)) {
    if ([string]::IsNullOrEmpty($dir)) { continue }
    $lnk = Join-Path $dir 'AgentsKontakt 邮差.lnk'
    try {
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = $exe
        $s.Arguments = '--minimized'
        $s.WorkingDirectory = $InstallDir
        $s.Description = 'AgentsKontakt 邮差 - 跨应用 AI 信箱邮局'
        $s.IconLocation = "$exe,0"
        $s.Save()
        # uninstall entry (v2.2.1): the Windows-install experience needs a
        # visible off switch. Uninstall removes the program together with the
        # data folder (2026-11-03, one-folder layout - no keep option).
        $lnkU = Join-Path $dir 'AgentsKontakt 卸载.lnk'
        $s2 = $ws.CreateShortcut($lnkU)
        $s2.TargetPath = $exe
        $s2.Arguments = '--uninstall'
        $s2.WorkingDirectory = $InstallDir
        $s2.Description = 'AgentsKontakt 卸载（应用与数据一并删除）'
        $s2.IconLocation = "$exe,0"
        $s2.Save()
        Write-Host ("  [ok] shortcut: {0} (+卸载)" -f $lnk)
    } catch {
        Write-Warning ("shortcut failed: {0}" -f $_.Exception.Message)
    }
}
} else {
    Write-Host '  [--] shortcuts skipped (-NoShortcuts)'
}

# ---- 4b. standard uninstall registration (v2.2.6): the HKCU Uninstall key
# makes the install visible in Settings->Apps and to any standard application
# enumeration (registry scan / AI discovery of installed apps).
$exeVer = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
$unKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentsKontaktPost'
try {
    $sizeKB = 0
    try { $sizeKB = [int][math]::Round((Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB) } catch { }
    New-Item -Path $unKey -Force | Out-Null
    Set-ItemProperty -Path $unKey -Name 'DisplayName'          -Value 'AgentsKontakt Postman（跨应用 AI 信箱邮局）'
    Set-ItemProperty -Path $unKey -Name 'DisplayVersion'       -Value $exeVer
    Set-ItemProperty -Path $unKey -Name 'Publisher'            -Value 'AgentsKontakt'
    Set-ItemProperty -Path $unKey -Name 'DisplayIcon'          -Value "$exe,0"
    Set-ItemProperty -Path $unKey -Name 'UninstallString'      -Value "`"$exe`" --uninstall"
    Set-ItemProperty -Path $unKey -Name 'QuietUninstallString' -Value "`"$exe`" --uninstall"
    Set-ItemProperty -Path $unKey -Name 'InstallLocation'      -Value $InstallDir
    Set-ItemProperty -Path $unKey -Name 'EstimatedSize'        -Value $sizeKB -Type DWord
    Set-ItemProperty -Path $unKey -Name 'NoModify'             -Value 1 -Type DWord
    Set-ItemProperty -Path $unKey -Name 'NoRepair'             -Value 1 -Type DWord
    Set-ItemProperty -Path $unKey -Name 'InstallDate'          -Value (Get-Date -Format 'yyyyMMdd')
    Set-ItemProperty -Path $unKey -Name 'Comments'             -Value '跨应用 AI 信箱邮局；agent 自助接入见安装目录 AGENTS.md'
    Write-Host '  [ok] standard uninstall entry registered (Settings->Apps)'
    New-Item 'HKCU:\Software\AgentsKontakt' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\AgentsKontakt' -Name 'LastInstallDir' -Value $InstallDir
} catch {
    Write-Warning ("uninstall registration failed: {0}" -f $_.Exception.Message)
}

# ---------------------------------------------------------------- 5. autostart
# Two layers, on purpose: the scheduled task keeps the post office running
# even when nobody opens the tray app; the HKCU Run entry starts the tray
# app itself at logon. Neither needs administrator rights.
$wantAutostart = $WithAutostart -and (-not $NoAutostart)
if ($wantAutostart) {
    # 2026-10-31 path fix: autostart.ps1 lives under scripts\ops\ (layered
    # layout); the old scripts\ reference silently skipped daemon autostart.
    $autostartPs = Join-Path $SourceRoot 'scripts\ops\autostart.ps1'
    if (-not (Test-Path -LiteralPath $autostartPs)) { $autostartPs = Join-Path $SourceRoot 'scripts\autostart.ps1' }
    if (Test-Path -LiteralPath $autostartPs) {
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $autostartPs -Action Register -DataDir $DataDir | Out-Null
            Write-Host '  [ok] daemon autostart registered (scheduled task)'
        } catch {
            Write-Warning ("daemon autostart failed: {0}" -f $_.Exception.Message)
        }
    }
    try {
        $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $rk)) { New-Item -Path $rk -Force | Out-Null }
        Set-ItemProperty -Path $rk -Name 'AgentsKontaktPost' -Value ('"' + $exe + '" --minimized') -Type String
        Write-Host '  [ok] tray app autostart registered (HKCU Run)'
    } catch {
        Write-Warning ("tray autostart registration failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 5b. defender exclusion
# The post office touches 600+ files per sweep and the real-time scan filter
# taxes every open (~2-60ms measured on stock Defender configs) - its single
# largest CPU cost. Excluding the app's own directories removes it. One UAC
# prompt; declining is a clean skip, never an install failure.
if (-not $NoDefenderExclusion) {
    $depPs = Join-Path $PSScriptRoot 'defender-exclusion.ps1'
    if (Test-Path -LiteralPath $depPs) {
        $exRoots = @($DataDir)
        if (-not [string]::Equals($InstallDir.TrimEnd('\'), $DataDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $exRoots += $InstallDir
        }
        # -File cannot collect repeated -Root into string[] (ParameterAlreadyBound,
        # reproduced 2026-10-31); -Command can. Paths are single-quoted with doubling.
        $depRoots = ($exRoots | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
        # Local Continue: a stderr record under Stop would abort install.ps1
        # before init (2026-10-31 path-A fallback incident). Never fatal.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$depPs' -Action Register -Root $depRoots" 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
        } catch {
            Write-Warning ("defender exclusion step failed (non-fatal): " + $_.Exception.Message)
        }
        $ErrorActionPreference = $eap
    }
}

# ---------------------------------------------------------------- 6. init tree
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDst 'init.ps1') -Root $DataDir | Out-Null
    Write-Host '  [ok] mailbox tree initialised'
} catch {
    Write-Warning ("init.ps1 failed: {0}" -f $_.Exception.Message)
}

Write-Host ''
Write-Host '=============================================================='
Write-Host ' Install finished.'
Write-Host ''
Write-Host ("  Start the postman : {0}" -f $exe)
Write-Host ("  Data directory    : {0}" -f $DataDir)
Write-Host ('  Enable autostart  : "' + $exe + '" --register-autostart')
Write-Host '=============================================================='
