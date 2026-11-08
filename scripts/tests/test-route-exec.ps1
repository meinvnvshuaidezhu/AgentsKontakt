<#
test-route-exec.ps1 - sandbox regression for route.ps1's exec-channel terminal
state (PROTOCOL.md 0.5 item 4) and instant-death detection.

Cases:
  1 fail-fast : wake `exec nosuchcmd_...` dies at once
                -> WARN + NOTIFY-FAILED + requeue to inbox, sidecar carries
                   "STATUS failed code=1 reason=...", dispatch.log has the trace
  2 long-run  : wake `exec Start-Sleep -Seconds N`
                -> route must NOT wait for the session: it answers DISPATCHED
                   well before the sleep ends, message stays in processing, no
                   premature STATUS; STATUS ok lands only when it really ends
  3 fast-ok   : wake `exec exit 0` -> DISPATCHED + STATUS ok
  4 fallback  : wake `exec <broken> | exec exit 0` -> first channel fails fast,
                second carries the mail, message stays in processing, last
                STATUS line is ok
  5 prompt    : wake writes {prompt} to a file -> the dispatch prompt (message
                path + non-ASCII template text) survives the base64/JSON
                payload and the argv boundary intact

Runs entirely in a throwaway sandbox root; no real mailbox is touched.
Exit code 0 = all cases passed.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\test-route-exec.ps1 [-Keep] [-ExecProbeMs 1200] [-SlowSeconds 8]
#>
param(
    [string]$Sandbox = '',
    [int]$ExecProbeMs = 3000,
    [int]$SlowSeconds = 8,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Failures = @()
$script:ScriptsDir = if (Test-Path (Join-Path $PSScriptRoot '..\core\route.ps1')) { (Resolve-Path (Join-Path $PSScriptRoot '..\core')).Path }
                     elseif (Test-Path (Join-Path $PSScriptRoot '..\route.ps1')) { (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path }
                     else { $PSScriptRoot }
$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not $Sandbox) {
    $Sandbox = Join-Path $env:TEMP ('AgentsKontakt-route-exec-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('  PASS  ' + $Name) }
    else { $script:Fail++; $script:Failures += ($Name + ' :: ' + $Detail); Write-Host ('  FAIL  ' + $Name + ' :: ' + $Detail) }
}

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

function Wait-ForRegex {
    param([string]$Path, [string]$Pattern, [int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $t = Read-Text -Path $Path
        if ($t -match $Pattern) { return $t }
        Start-Sleep -Milliseconds 250
    }
    return (Read-Text -Path $Path)
}

function New-Agent {
    param([string]$Root, [string]$Name, [string]$Wake)
    $card = @"
---
name: $Name
inbox: mailboxes\$Name\inbox
wake: $Wake
model: sandbox
owner: regression
registered: 2026-10-02T00:00:00+08:00
last_seen: (never)
---

route.ps1 exec-channel regression agent (throwaway sandbox).
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Root ('registry\' + $Name + '.md')), $card, $utf8)
    foreach ($d in @('inbox', 'processing', 'outbox')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root ('mailboxes\' + $Name + '\' + $d)) | Out-Null
    }
}

function New-Message {
    param([string]$Root, [string]$Agent, [string]$Id, [string]$Topic)
    $body = @"
---
id: $Id
topic: $Topic
from: regression
to: $Agent
type: request
subject: sandbox exec channel case
created: 2026-10-02T15:00:00.000+08:00
state: open
---

sandbox message for route.ps1 exec-channel regression.
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $p = Join-Path $Root ('mailboxes\' + $Agent + '\inbox\' + $Id + '.md')
    [System.IO.File]::WriteAllText($p, $body, $utf8)
    return $p
}

function Invoke-Route {
    # route.ps1 is invoked in-process (& route.ps1) exactly the way send.ps1 and
    # watch.ps1 invoke it; the throwaway runner is the child process that
    # absorbs route's `exit` and reports its exit code / stdout back here.
    param([string]$Sandbox, [string]$Msg, [int]$ProbeMs)
    $runner = Join-Path $Sandbox 'run-route.ps1'
    $route = Join-Path $script:ScriptsDir 'route.ps1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Route $route -Root $Sandbox -Msg $Msg -ProbeMs $ProbeMs 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    return [pscustomobject]@{ Output = ($out | Out-String); Code = $code; Seconds = $sw.Elapsed.TotalSeconds }
}

# ---------------------------------------------------------------- sandbox tree
Write-Host ('sandbox: ' + $Sandbox)
if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
foreach ($d in @('registry', 'mailboxes', 'archive', 'logs', 'logs\routed', 'templates')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox $d) | Out-Null
}
# Canonical long path: route.ps1 canonicalizes $Root and records the message
# path in its canonical form, so the test must compare against the same form.
$Sandbox = (Get-Item -LiteralPath $Sandbox).FullName
$repoTemplates = Join-Path $script:RepoRoot 'templates'
foreach ($t in @('dispatch-prompt.txt', 'dashboard-template.html')) {
    $src = Join-Path $repoTemplates $t
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Sandbox ('templates\' + $t)) -Force }
}

New-Agent -Root $Sandbox -Name 'rt-fail'     -Wake 'exec nosuchcmd_ak_regression'
New-Agent -Root $Sandbox -Name 'rt-slow'     -Wake ('exec Start-Sleep -Seconds ' + $SlowSeconds)
New-Agent -Root $Sandbox -Name 'rt-fastok'   -Wake 'exec exit 0'
New-Agent -Root $Sandbox -Name 'rt-fallback' -Wake 'exec nosuchcmd_ak_regression | exec exit 0'
$promptOutPath = Join-Path $Sandbox 'prompt-out.txt'
# NOTE: {prompt} is substituted WITH its surrounding quotes by route.ps1, so the
# wake command must not quote it again (the documented card footgun).
New-Agent -Root $Sandbox -Name 'rt-prompt'   -Wake ("exec [IO.File]::WriteAllText('" + $promptOutPath + "',{prompt})")

# In-process runner: route.ps1 must be invoked the way send.ps1/watch.ps1 do
# (& route.ps1), with a real child process absorbing route's `exit`.
$runnerSrc = @'
param([string]$Route, [string]$Root, [string]$Msg, [int]$ProbeMs)
$LASTEXITCODE = 0
& $Route -File $Msg -Root $Root -ExecProbeMs $ProbeMs
exit $LASTEXITCODE
'@
[System.IO.File]::WriteAllText((Join-Path $Sandbox 'run-route.ps1'), $runnerSrc, (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------- case 1: fail-fast/requeue
Write-Host 'case 1: fail-fast exec -> WARN + requeue, STATUS failed in sidecar'
$id1 = 'msg-20261002-150001-rtfail-a001'
$m1 = New-Message -Root $Sandbox -Agent 'rt-fail' -Id $id1 -Topic 't-20261002-sbx1'
$r1 = Invoke-Route -Sandbox $Sandbox -Msg $m1 -ProbeMs $ExecProbeMs
Write-Host ('  info  C1 route returned in ' + [math]::Round($r1.Seconds, 2) + 's (grace ' + ($ExecProbeMs / 1000.0) + 's)')
$side1 = Join-Path $Sandbox ('mailboxes\rt-fail\inbox\' + $id1 + '.progress')
$s1 = Read-Text -Path $side1
$log1 = Join-Path $Sandbox 'logs\rt-fail\dispatch.log'
Check 'C1 route answers NOTIFY-FAILED' ($r1.Output -match 'NOTIFY-FAILED') $r1.Output
Check 'C1 route exits non-zero' ($r1.Code -ne 0) ('exit=' + $r1.Code)
Check 'C1 message requeued to inbox' (Test-Path -LiteralPath $m1)
Check 'C1 message not left in processing' (-not (Test-Path -LiteralPath (Join-Path $Sandbox ('mailboxes\rt-fail\processing\' + $id1 + '.md'))))
Check 'C1 sidecar moved to inbox with message' (Test-Path -LiteralPath $side1)
Check 'C1 sidecar carries STATUS failed code=1' ($s1 -match '(?m)^STATUS failed code=1\b') $s1
Check 'C1 sidecar reason mentions exit' ($s1 -match 'reason=.*non-zero') $s1
Check 'C1 dispatch.log records the exit' ((Read-Text -Path $log1) -match ('exit=1 .*seconds=')) (Read-Text -Path $log1)
Check 'C1 detected within grace' ($r1.Seconds -lt (($ExecProbeMs / 1000.0) + 6)) ('seconds=' + $r1.Seconds)

# ------------------------------------------- case 2: long session is not waited on
Write-Host 'case 2: long-running exec -> route returns at once, STATUS ok at real exit'
$id2 = 'msg-20261002-150002-rtslow-a002'
$m2 = New-Message -Root $Sandbox -Agent 'rt-slow' -Id $id2 -Topic 't-20261002-sbx2'
$r2 = Invoke-Route -Sandbox $Sandbox -Msg $m2 -ProbeMs $ExecProbeMs
Write-Host ('  info  C2 route returned in ' + [math]::Round($r2.Seconds, 2) + 's (session runs ' + $SlowSeconds + 's)')
$side2 = Join-Path $Sandbox ('mailboxes\rt-slow\processing\' + $id2 + '.progress')
$s2early = Read-Text -Path $side2
Check 'C2 route answers DISPATCHED' ($r2.Output -match 'DISPATCHED') $r2.Output
Check 'C2 route did not wait for the session' ($r2.Seconds -lt ($SlowSeconds - 3)) ('seconds=' + $r2.Seconds + ' slow=' + $SlowSeconds)
Check 'C2 message stays in processing' (Test-Path -LiteralPath (Join-Path $Sandbox ('mailboxes\rt-slow\processing\' + $id2 + '.md')))
Check 'C2 no premature terminal STATUS' (-not ($s2early -match '(?m)^STATUS\s')) $s2early

# --------------------------------------------------------- case 3: normal quick exit
Write-Host 'case 3: fast normal exit -> STATUS ok'
$id3 = 'msg-20261002-150003-rtfastok-a003'
$m3 = New-Message -Root $Sandbox -Agent 'rt-fastok' -Id $id3 -Topic 't-20261002-sbx3'
$r3 = Invoke-Route -Sandbox $Sandbox -Msg $m3 -ProbeMs $ExecProbeMs
Write-Host ('  info  C3 route returned in ' + [math]::Round($r3.Seconds, 2) + 's')
$side3 = Join-Path $Sandbox ('mailboxes\rt-fastok\processing\' + $id3 + '.progress')
$s3 = Wait-ForRegex -Path $side3 -Pattern '(?m)^STATUS ok\s*$' -Seconds 15
Check 'C3 route answers DISPATCHED' ($r3.Output -match 'DISPATCHED') $r3.Output
Check 'C3 message stays in processing' (Test-Path -LiteralPath (Join-Path $Sandbox ('mailboxes\rt-fastok\processing\' + $id3 + '.md')))
Check 'C3 sidecar carries STATUS ok' ($s3 -match '(?m)^STATUS ok\s*$') $s3

# ------------------------------------------------- case 4: dead channel falls back
Write-Host 'case 4: broken first channel -> fallback carries the mail'
$id4 = 'msg-20261002-150004-rtfallback-a004'
$m4 = New-Message -Root $Sandbox -Agent 'rt-fallback' -Id $id4 -Topic 't-20261002-sbx4'
$r4 = Invoke-Route -Sandbox $Sandbox -Msg $m4 -ProbeMs $ExecProbeMs
Write-Host ('  info  C4 route returned in ' + [math]::Round($r4.Seconds, 2) + 's')
$side4 = Join-Path $Sandbox ('mailboxes\rt-fallback\processing\' + $id4 + '.progress')
$s4 = Wait-ForRegex -Path $side4 -Pattern '(?m)^STATUS ok\s*$' -Seconds 15
$status4 = @($s4 -split "`r?`n" | Where-Object { $_ -match '^STATUS\s' })
$last4 = if ($status4.Count -gt 0) { $status4[-1] } else { '<none>' }
Check 'C4 route answers DISPATCHED' ($r4.Output -match 'DISPATCHED') $r4.Output
Check 'C4 message stays in processing' (Test-Path -LiteralPath (Join-Path $Sandbox ('mailboxes\rt-fallback\processing\' + $id4 + '.md')))
Check 'C4 earlier failure is recorded' ($s4 -match '(?m)^STATUS failed') $s4
Check 'C4 last STATUS line is ok' ($last4 -match '^STATUS ok') $last4

# ------------------------------- case 5: {prompt} + non-ASCII payload round trip
Write-Host 'case 5: {prompt} substitution survives the base64/JSON payload'
$id5 = 'msg-20261002-150005-rtprompt-a005'
$m5 = New-Message -Root $Sandbox -Agent 'rt-prompt' -Id $id5 -Topic 't-20261002-sbx5'
$r5 = Invoke-Route -Sandbox $Sandbox -Msg $m5 -ProbeMs $ExecProbeMs
Write-Host ('  info  C5 route returned in ' + [math]::Round($r5.Seconds, 2) + 's')
$side5 = Join-Path $Sandbox ('mailboxes\rt-prompt\processing\' + $id5 + '.progress')
$s5 = Wait-ForRegex -Path $side5 -Pattern '(?m)^STATUS ok\s*$' -Seconds 15
$promptText = Read-Text -Path $promptOutPath
$expectedPrompt = [System.IO.File]::ReadAllText((Join-Path $Sandbox 'templates\dispatch-prompt.txt'))
$expectedPrompt = $expectedPrompt.Trim().Replace('{path}', (Join-Path $Sandbox ('mailboxes\rt-prompt\processing\' + $id5 + '.md')))
$expectedPrompt = $expectedPrompt.Replace("'", '').Replace('"', '')
Check 'C5 route answers DISPATCHED' ($r5.Output -match 'DISPATCHED') $r5.Output
Check 'C5 wake command received a prompt' ($promptText.Length -gt 100) ('len=' + $promptText.Length)
Check 'C5 prompt carries the claimed (processing) path' ($promptText -match [regex]::Escape((Join-Path $Sandbox ('mailboxes\rt-prompt\processing\' + $id5 + '.md')))) $promptText
Check 'C5 prompt is the dispatch template' ($promptText -match 'PROTOCOL') $promptText
Check 'C5 prompt round-trips byte-for-byte (non-ASCII intact)' ($promptText -eq $expectedPrompt) ('got=' + $promptText.Length + ' want=' + $expectedPrompt.Length)
Check 'C5 STATUS ok' ($s5 -match '(?m)^STATUS ok\s*$') $s5

# ------------------------------------- case 2 tail: STATUS ok once the sleep ends
Write-Host 'case 2 (tail): STATUS ok after the long session really ends'
$s2 = Wait-ForRegex -Path $side2 -Pattern '(?m)^STATUS ok\s*$' -Seconds ($SlowSeconds + 20)
Check 'C2 STATUS ok after real exit' ($s2 -match '(?m)^STATUS ok\s*$') $s2

# ------------------------------------------------------------------------ summary
Write-Host ''
Write-Host ('route-exec regression: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -gt 0) {
    foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) }
}
if ($Keep) {
    Write-Host ('sandbox kept: ' + $Sandbox)
} else {
    Start-Sleep -Milliseconds 800
    try { Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction Stop } catch { Write-Host ('sandbox cleanup skipped: ' + $_.Exception.Message) }
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
