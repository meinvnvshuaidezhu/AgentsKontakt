<#
test-deadletter.ps1 - sandbox regression for route.ps1's dispatch guards
(2026-10-29 lag fix) and cleanup.ps1's sys-mail retention.

Cases:
  A busy-skip    : recipient mid-session (fresh activity under processing/)
                   -> route answers QUEUED-BUSY, no claim, the wake command
                   never spawns, WARN-once flag recorded
  B exhausted    : sidecar shows 3 prior DISPATCHED rounds, recipient quiet
                   -> copy + sidecar removed, sender master stamped RETURNED,
                   bounce sys-mail lands in the sender's inbox
  C sys-exhausted: same exhaustion on a sys-* mail -> dropped silently,
                   no bounce (postmaster has no mailbox)
  D carry        : the claim carries inbox\<id>.progress into processing; the
                   DISPATCHED count accumulates across requeue rounds
                   (2 seeded + 1 new = 3)
  E cleanup      : sys mails and orphan sidecars past sys_retention_days are
                   purged from inbox and processing; stale non-sys processing
                   mail is still requeued; fresh mail untouched

Runs entirely in a throwaway sandbox root; no real mailbox is touched.
Exit code 0 = all cases passed.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\test-deadletter.ps1 [-Keep]
#>
param(
    [string]$Sandbox = '',
    [int]$ExecProbeMs = 1200,
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
    $Sandbox = Join-Path $env:TEMP ('AgentsKontakt-deadletter-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    param([string]$Path, [string]$Pattern, [int]$Seconds = 20)
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
registered: 2026-10-29T00:00:00+08:00
last_seen: (never)
---

route.ps1 dispatch-guard regression agent (throwaway sandbox).
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Root ('registry\' + $Name + '.md')), $card, $utf8)
    foreach ($d in @('inbox', 'processing', 'outbox', 'sent', 'notes')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root ('mailboxes\' + $Name + '\' + $d)) | Out-Null
    }
}

function New-Message {
    param([string]$Root, [string]$Agent, [string]$From, [string]$Id, [string]$Topic, [string]$Type = 'request')
    $body = @"
---
id: $Id
topic: $Topic
from: $From
to: $Agent
type: $Type
subject: sandbox dispatch-guard case
created: 2026-10-29T10:00:00.000+08:00
state: open
---

sandbox message for the dead-letter regression.
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $p = Join-Path $Root ('mailboxes\' + $Agent + '\inbox\' + $Id + '.md')
    [System.IO.File]::WriteAllText($p, $body, $utf8)
    return $p
}

function Add-Attempts {
    # Seed the dispatch sidecar next to the letter with N prior DISPATCHED
    # rounds - exactly what a requeue cycle accumulates in production.
    param([string]$MdPath, [int]$Count)
    $side = [System.IO.Path]::ChangeExtension($MdPath, '.progress')
    $lines = ''
    for ($i = 0; $i -lt $Count; $i++) {
        $lines += '[2026-10-2' + (1 + $i) + ' 10:00:00] DISPATCHED (post office notifying via registered channels)' + "`r`n"
    }
    [System.IO.File]::AppendAllText($side, $lines, (New-Object System.Text.UTF8Encoding($false)))
    return $side
}

function Invoke-Route {
    param([string]$Sandbox, [string]$Msg, [int]$ProbeMs)
    $runner = Join-Path $Sandbox 'run-route.ps1'
    $route = Join-Path $script:ScriptsDir 'route.ps1'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Route $route -Root $Sandbox -Msg $Msg -ProbeMs $ProbeMs 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Output = ($out | Out-String); Code = $code }
}

# ---------------------------------------------------------------- sandbox tree
Write-Host ('sandbox: ' + $Sandbox)
if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
foreach ($d in @('registry', 'mailboxes', 'archive', 'logs', 'logs\routed', 'templates')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox $d) | Out-Null
}
$Sandbox = (Get-Item -LiteralPath $Sandbox).FullName
$repoTemplates = Join-Path $script:RepoRoot 'templates'
foreach ($t in @('dispatch-prompt.txt', 'dashboard-template.html')) {
    $src = Join-Path $repoTemplates $t
    if (Test-Path -LiteralPath $src) { Copy-Item $src -Destination (Join-Path $Sandbox ('templates\' + $t)) -Force }
}

$busyWakeMarker = Join-Path $Sandbox 'busy-wake-fired.txt'
New-Agent -Root $Sandbox -Name 'dl-busy'  -Wake ("exec [IO.File]::WriteAllText('" + $busyWakeMarker + "','fired')")
New-Agent -Root $Sandbox -Name 'dl-dead'  -Wake 'exec exit 0'
New-Agent -Root $Sandbox -Name 'dl-carry' -Wake 'exec exit 0'
New-Agent -Root $Sandbox -Name 'dl-send'  -Wake 'TODO'

$runnerSrc = @'
param([string]$Route, [string]$Root, [string]$Msg, [int]$ProbeMs)
$LASTEXITCODE = 0
& $Route -File $Msg -Root $Root -ExecProbeMs $ProbeMs
exit $LASTEXITCODE
'@
[System.IO.File]::WriteAllText((Join-Path $Sandbox 'run-route.ps1'), $runnerSrc, (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------ case A: busy recipient
Write-Host 'case A: recipient busy -> QUEUED-BUSY, no claim, no wake spawn'
$idA = 'msg-20261029-100001-dlsend-a001'
$mA = New-Message -Root $Sandbox -Agent 'dl-busy' -From 'dl-send' -Id $idA -Topic 't-20261029-sba1'
# fresh activity in the recipient's processing zone = mid-session
$peerWork = Join-Path $Sandbox 'mailboxes\dl-busy\processing\msg-other-0001.progress'
[System.IO.File]::WriteAllText($peerWork, '[now] working', (New-Object System.Text.UTF8Encoding($false)))
$rA = Invoke-Route -Sandbox $Sandbox -Msg $mA -ProbeMs $ExecProbeMs
Check 'CA route answers QUEUED-BUSY'       ($rA.Output -match 'QUEUED-BUSY') $rA.Output
Check 'CA route exits 0'                   ($rA.Code -eq 0) ('exit=' + $rA.Code)
Check 'CA letter stays in inbox'           (Test-Path -LiteralPath $mA)
Check 'CA no DISPATCHED sidecar created'   (-not (Test-Path -LiteralPath ((Join-Path $Sandbox 'mailboxes\dl-busy\processing') + '\' + $idA + '.progress')))
Check 'CA wake command never spawned'      (-not (Test-Path -LiteralPath $busyWakeMarker))
Check 'CA WARN-once flag recorded'         (Test-Path -LiteralPath (Join-Path $Sandbox ('logs\routed\' + $idA + '.busy.flag')))
Check 'CA journal notes the deferral'      ((Read-Text (Join-Path $Sandbox 'logs\dl-busy\journal.log')) -match 'recipient busy') (Read-Text (Join-Path $Sandbox 'logs\dl-busy\journal.log'))

# ------------------------------------------- case C: exhausted sys mail dropped
Write-Host 'case C: exhausted sys mail -> dropped silently, no bounce'
$idC = 'sys-20261029-100003-dead-c003'
$mC = New-Message -Root $Sandbox -Agent 'dl-dead' -From 'postmaster' -Id $idC -Topic 't-20261029-sbc3' -Type 'broadcast'
$sideC = Add-Attempts -MdPath $mC -Count 3
$sysBefore = @(Get-ChildItem (Join-Path $Sandbox 'mailboxes\dl-send\inbox') -Filter 'sys-*.md' -ErrorAction SilentlyContinue).Count
$rC = Invoke-Route -Sandbox $Sandbox -Msg $mC -ProbeMs $ExecProbeMs
$sysAfter = @(Get-ChildItem (Join-Path $Sandbox 'mailboxes\dl-send\inbox') -Filter 'sys-*.md' -ErrorAction SilentlyContinue).Count
Check 'CC route answers RETURNED exhausted' ($rC.Output -match 'RETURNED .*attempts exhausted') $rC.Output
Check 'CC route exits 0'                    ($rC.Code -eq 0) ('exit=' + $rC.Code)
Check 'CC sys copy removed'                 (-not (Test-Path -LiteralPath $mC))
Check 'CC sys sidecar removed'              (-not (Test-Path -LiteralPath $sideC))
Check 'CC no bounce mail to anyone'         ($sysAfter -eq $sysBefore) ('before=' + $sysBefore + ' after=' + $sysAfter)
Check 'CC drop recorded in system log'      ((Read-Text (Join-Path $Sandbox 'logs\system.log')) -match 'sys mail dropped') (Read-Text (Join-Path $Sandbox 'logs\system.log'))

# --------------------------------------- case B: exhausted letter -> return to sender
Write-Host 'case B: attempts exhausted -> returned to sender with bounce'
$idB = 'msg-20261029-100002-dlsend-b002'
$mB = New-Message -Root $Sandbox -Agent 'dl-dead' -From 'dl-send' -Id $idB -Topic 't-20261029-sbb2'
$sideB = Add-Attempts -MdPath $mB -Count 3
# the sender's in-flight master (what send.ps1 parks in sent\ at take-out)
$masterB = Join-Path $Sandbox ('mailboxes\dl-send\sent\' + $idB + '.md')
[System.IO.File]::Copy($mB, $masterB)
$rB = Invoke-Route -Sandbox $Sandbox -Msg $mB -ProbeMs $ExecProbeMs
$masterSideB = Join-Path $Sandbox ('mailboxes\dl-send\sent\' + $idB + '.status')
$sB = Read-Text -Path $masterSideB
$bounces = @(Get-ChildItem (Join-Path $Sandbox 'mailboxes\dl-send\inbox') -Filter 'sys-*.md' -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match ('RETURNED ' + $idB) })
Check 'CB route answers RETURNED exhausted' ($rB.Output -match 'RETURNED .*attempts exhausted') $rB.Output
Check 'CB route exits 0'                    ($rB.Code -eq 0) ('exit=' + $rB.Code)
Check 'CB cycling copy removed'             (-not (Test-Path -LiteralPath $mB))
Check 'CB cycling sidecar removed'          (-not (Test-Path -LiteralPath $sideB))
Check 'CB sender master still in sent'      (Test-Path -LiteralPath $masterB)
Check 'CB master status RETURNED'           ($sB -match '(?m)^status:\s*RETURNED\s*$') $sB
Check 'CB master reason mentions exhaustion'($sB -match 'exhausted') $sB
Check 'CB bounce sys-mail in sender inbox'  ($bounces.Count -ge 1)
Check 'CB journal records the return'       ((Read-Text (Join-Path $Sandbox 'logs\dl-dead\journal.log')) -match ('returned to dl-send')) (Read-Text (Join-Path $Sandbox 'logs\dl-dead\journal.log'))

# ------------------------------------- case D: claim carries the sidecar along
Write-Host 'case D: claim carries the dispatch sidecar, count accumulates'
$idD = 'msg-20261029-100004-dlsend-d004'
$mD = New-Message -Root $Sandbox -Agent 'dl-carry' -From 'dl-send' -Id $idD -Topic 't-20261029-sbd4'
$sideD = Add-Attempts -MdPath $mD -Count 2
$rD = Invoke-Route -Sandbox $Sandbox -Msg $mD -ProbeMs $ExecProbeMs
$procSideD = Join-Path $Sandbox ('mailboxes\dl-carry\processing\' + $idD + '.progress')
$sD = Wait-ForRegex -Path $procSideD -Pattern '(?m)^STATUS ok\s*$'
$dispCount = ([regex]::Matches($sD, 'DISPATCHED \(post office')).Count
Check 'CD route answers DISPATCHED'         ($rD.Output -match 'DISPATCHED') $rD.Output
Check 'CD letter claimed to processing'     (Test-Path -LiteralPath ((Join-Path $Sandbox 'mailboxes\dl-carry\processing') + '\' + $idD + '.md'))
Check 'CD inbox sidecar carried (no orphan)'(-not (Test-Path -LiteralPath $sideD))
Check 'CD carried sidecar in processing'    (Test-Path -LiteralPath $procSideD)
Check 'CD DISPATCHED count accumulated (2+1)'($dispCount -eq 3) ('count=' + $dispCount)
Check 'CD STATUS ok after quick wake'       ($sD -match '(?m)^STATUS ok\s*$') $sD

# ------------------------------------------- case E: cleanup sys-mail retention
Write-Host 'case E: cleanup purges aged sys mail + orphan sidecars, keeps the rest'
$utf8e = New-Object System.Text.UTF8Encoding($false)
$inbS = Join-Path $Sandbox 'mailboxes\dl-send\inbox'
$procD = Join-Path $Sandbox 'mailboxes\dl-dead\processing'
# aged sys mail in inbox (purge) + fresh sys mail in inbox (keep)
$sysOld = Join-Path $inbS 'sys-20261024-100000-dead-e001.md'
[System.IO.File]::WriteAllText($sysOld, '---' + "`r`n" + 'id: sys-20261024-100000-dead-e001' + "`r`n" + '---' + "`r`n", $utf8e)
(Get-Item -LiteralPath $sysOld).LastWriteTime = (Get-Date).AddDays(-5)
$sysNew = Join-Path $inbS 'sys-20261029-100000-dead-e002.md'
[System.IO.File]::WriteAllText($sysNew, '---' + "`r`n" + 'id: sys-20261029-100000-dead-e002' + "`r`n" + '---' + "`r`n", $utf8e)
# orphan sidecar in inbox, letter long gone (purge)
$orphan = Join-Path $inbS 'msg-20261020-100000-dead-e003.progress'
[System.IO.File]::WriteAllText($orphan, '[stale] DISPATCHED', $utf8e)
(Get-Item -LiteralPath $orphan).LastWriteTime = (Get-Date).AddDays(-5)
# aged sys mail in processing + its sidecar (purge, NOT requeued)
$sysProc = Join-Path $procD 'sys-20261024-110000-dead-e004.md'
[System.IO.File]::WriteAllText($sysProc, '---' + "`r`n" + 'id: sys-20261024-110000-dead-e004' + "`r`n" + '---' + "`r`n", $utf8e)
(Get-Item -LiteralPath $sysProc).LastWriteTime = (Get-Date).AddDays(-5)
$sysProcSide = Join-Path $procD 'sys-20261024-110000-dead-e004.progress'
[System.IO.File]::WriteAllText($sysProcSide, '[stale]', $utf8e)
(Get-Item -LiteralPath $sysProcSide).LastWriteTime = (Get-Date).AddDays(-5)
# stale non-sys processing mail without heartbeat (still requeued, not deleted)
$staleMd = Join-Path $procD 'msg-20261024-120000-dlsend-e005.md'
[System.IO.File]::WriteAllText($staleMd, '---' + "`r`n" + 'id: msg-20261024-120000-dlsend-e005' + "`r`n" + 'topic: t-20261029-sbe5' + "`r`n" + '---' + "`r`n", $utf8e)
(Get-Item -LiteralPath $staleMd).LastWriteTime = (Get-Date).AddDays(-5)
$outE = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'cleanup.ps1') -Root $Sandbox 2>&1 | Out-String
Check 'CE cleanup exits 0'                  ($LASTEXITCODE -eq 0) $outE
Check 'CE aged sys mail purged from inbox'  (-not (Test-Path -LiteralPath $sysOld))
Check 'CE fresh sys mail kept in inbox'     (Test-Path -LiteralPath $sysNew)
Check 'CE aged orphan sidecar purged'       (-not (Test-Path -LiteralPath $orphan))
Check 'CE aged sys mail purged from processing' (-not (Test-Path -LiteralPath $sysProc))
Check 'CE aged sys sidecar purged'          (-not (Test-Path -LiteralPath $sysProcSide))
Check 'CE stale non-sys requeued, not deleted' (-not (Test-Path -LiteralPath $staleMd) -and (Test-Path -LiteralPath (Join-Path $Sandbox 'mailboxes\dl-dead\inbox\msg-20261024-120000-dlsend-e005.md')))

# ------------------------------------------------------------------------ summary
Write-Host ''
Write-Host ('deadletter regression: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
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
