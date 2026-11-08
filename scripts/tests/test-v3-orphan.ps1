param(
  [string]$Root = '',
  [switch]$Keep
)
$ErrorActionPreference = 'Continue'

# v3 orphan recycle-station acceptance (n5w8 §4 A1-A12).
# A4 and A5 are the red lines: zero false-positives on a healthy chain, and
# report-class findings are never moved. Runs in a throwaway root (E-drive
# stays data-free). workbuddy re-runs this table verbatim at acceptance.

$scriptRoot = Split-Path $PSScriptRoot -Parent
# A1 (t-20261107-ix07, P0): the finally block deletes $Root on a green run.
# With the default that is the throwaway temp root - fine. With an EXTERNAL
# -Root (run-tests.ps1 used to inject its sandbox here) it deleted the
# caller's data tree. The default must be applied AFTER this capture.
$rootProvided = [bool]$Root
if (-not $Root) { $Root = Join-Path ([System.IO.Path]::GetTempPath()) ('ak-v3-orphan-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Maximum 9999)) }
$pass = 0; $fail = 0
function Assert {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ('  [ok]   ' + $Name) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  :: ' + $Detail })) }
}
function Invoke-Scan { param([string]$ExtraArgs = '') (Join-Path $Root 'scripts\orphan-scan.ps1'), $ExtraArgs }
function Run-Orphan {
    param([string]$SwitchLine = '')
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'orphan-scan.ps1') -Root $Root $(if ($SwitchLine) { $SwitchLine.Split(' ') }) 2>&1 | Out-String
    return $out
}
function New-LetterFile {
    param([string]$Path, [string]$Id, [string]$Topic, [string]$From, [string]$To, [string]$Type = 'request', [string]$Body = 'orphan test body')
    $nl = "`r`n"
    $fm = '---' + $nl + 'id: ' + $Id + $nl + 'topic: ' + $Topic + $nl + 'subject: orphan test' + $nl +
          'from: ' + $From + $nl + 'to: ' + $To + $nl + 'type: ' + $Type + $nl +
          'created: 2026-01-01T00:00:00+08:00' + $nl + 'state: open' + $nl + '---' + $nl + $nl + $Body + $nl
    [System.IO.File]::WriteAllText($Path, $fm, (New-Object System.Text.UTF8Encoding($true)))
    return $Path
}

Write-Host ('v3 orphan acceptance root: ' + $Root)
foreach ($d in @('registry','logs','logs\routed','post\manifest','mailboxes\alice\inbox','mailboxes\alice\outbox','mailboxes\alice\processing','mailboxes\alice\sent','mailboxes\alice\notes','mailboxes\bob\inbox','mailboxes\bob\outbox','mailboxes\bob\processing','mailboxes\bob\sent','mailboxes\bob\notes','templates','config')) {
    New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
}
Copy-Item -Path (Join-Path (Split-Path $scriptRoot -Parent) 'templates\*') -Destination (Join-Path $Root 'templates') -Recurse -Force
$card = "---`r`nname: {0}`r`ninbox: mailboxes\{0}\inbox`r`nmodel: test-model`r`nwake: TODO`r`n---`r`n"
foreach ($a in @('alice', 'bob')) { [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'registry') ($a + '.md')), ($card -f $a), (New-Object System.Text.UTF8Encoding($true))) }
$env:MAILBOX_ROOT = $Root

try {
    # ---- A1: cold-quarantine letter is binned ----
    Write-Host 'A1 cold-quarantine letter enters the trash'
    $cold = Join-Path (Join-Path $Root 'post') 'cold'
    New-Item -ItemType Directory -Path $cold -Force | Out-Null
    $coldFile = Join-Path $cold 'msg-20260101-000000-alice-cld1.md'
    New-LetterFile -Path $coldFile -Id msg-20260101-000000-alice-cld1 -Topic t-20260101-orp1 -From alice -To bob
    (Get-Item $coldFile).LastWriteTime = (Get-Date).AddMinutes(-2)   # past the 1-minute write valve
    $o = Run-Orphan '-MoveToTrash'
    Assert 'A1 cold file cleared from origin'  (-not (Test-Path $coldFile)) $o
    $binDirs = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'meta.json') })
    Assert 'A1 trash dir has item + meta'      ($binDirs.Count -ge 1 -and (Test-Path (Join-Path $binDirs[0].FullName 'meta.json')) -and (Test-Path (Join-Path $binDirs[0].FullName 'item.md')))
    $meta1 = [System.IO.File]::ReadAllText((Join-Path $binDirs[0].FullName 'meta.json')) | ConvertFrom-Json
    Assert 'A1 meta.original_path points to cold' ($meta1.original_path -eq $coldFile)

    # ---- A2: index.json in sync ----
    Write-Host 'A2 index.json in sync with the trash dir'
    $idx = [System.IO.File]::ReadAllText((Join-Path $Root 'post\trash\index.json')) | ConvertFrom-Json
    $dirCount = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'meta.json') }).Count
    Assert 'A2 count matches dir count'        ($idx.count -eq $dirCount)
    Assert 'A2 index contains the trash_id'    ($idx.items.trash_id -contains $meta1.trash_id)

    # ---- A3: age gate (fresh bad-name mail NOT binned; 25h old IS) ----
    Write-Host 'A3 age gate: fresh bad-name mail stays, 25h-old enters'
    $sentDir = Join-Path (Join-Path $Root 'mailboxes') 'alice\sent'
    $badFresh = Join-Path $sentDir 't-20260101-orp3.chain.md.bad'
    # a bad-NAME letter: .md extension but a name no reader recognizes
    $badFresh = Join-Path $sentDir 'weird-20260101.md'
    New-LetterFile -Path $badFresh -Id msg-20260101-000000-alice-bad3 -Topic t-20260101-orp3 -From alice -To bob
    $null = Run-Orphan
    Assert 'A3 fresh bad-name mail NOT binned' (-not (Test-Path (Join-Path (Join-Path $Root 'post\trash\index.json') 'x')) -and (Test-Path $badFresh)) 'fresh file must stay'
    $binAfterA3a = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory).Count
    (Get-Item $badFresh).LastWriteTime = (Get-Date).AddHours(-25)
    $null = Run-Orphan '-MoveToTrash'
    Assert 'A3 25h-old bad-name mail binned'   (-not (Test-Path $badFresh))
    $binAfterA3b = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory).Count
    Assert 'A3 binned count grew by 1'         ($binAfterA3b -eq $binAfterA3a + 1)

    # ---- A4 (RED LINE): zero false positives after a full healthy chain ----
    Write-Host 'A4 red line: full healthy chain produces zero findings'
    $send = Join-Path $scriptRoot 'send.ps1'
    $nl = "`r`n"
    $l1 = Join-Path (Join-Path $Root 'mailboxes\alice\outbox') 'msg-20260101-000000-alice-a4a1.md'
    New-LetterFile -Path $l1 -Id msg-20260101-000000-alice-a4a1 -Topic t-20260101-orp4 -From alice -To bob -Body 'a4 body'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $send -File $l1 -Root $Root 2>&1
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'claim.ps1') -File (Join-Path (Join-Path (Join-Path $Root 'mailboxes') 'bob\inbox') 't-20260101-orp4.chain.md') -Root $Root 2>&1
    $l2 = Join-Path (Join-Path $Root 'mailboxes\bob\outbox') 'msg-20260101-000001-bob-a4a2.md'
    New-LetterFile -Path $l2 -Id msg-20260101-000001-bob-a4a2 -Topic t-20260101-orp4 -From bob -To alice -Type reply -Body 'a4 answer' -InReplyTo 'msg-20260101-000000-alice-a4a1'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $send -File $l2 -Root $Root 2>&1
    $countsBefore = @{}
    foreach ($a in @('alice', 'bob')) { foreach ($z in @('inbox', 'processing', 'sent')) {
        $countsBefore[$a + '\' + $z] = @(Get-ChildItem (Join-Path (Join-Path (Join-Path $Root 'mailboxes') $a) $z) -File -ErrorAction SilentlyContinue).Count
    } }
    $o4 = Run-Orphan
    $zeroFindings = -not ($o4 -match '(?m)^(TRASH|REPORT)\s')   # summary line legitimately says "trash 0, report 0"
    Assert 'A4 zero findings after a healthy chain' ($zeroFindings) $o4
    $noMove = $true
    foreach ($a in @('alice', 'bob')) { foreach ($z in @('inbox', 'processing', 'sent')) {
        if ($countsBefore[$a + '\' + $z] -ne @(Get-ChildItem (Join-Path (Join-Path (Join-Path $Root 'mailboxes') $a) $z) -File -ErrorAction SilentlyContinue).Count) { $noMove = $false }
    } }
    Assert 'A4 mailbox file counts unchanged'  $noMove

    # ---- A5 (RED LINE): report-class thread dirs are NEVER moved ----
    Write-Host 'A5 red line: thread-no-status dir stays put even with -MoveToTrash'
    $noStatus = Join-Path (Join-Path $Root 'post\threads') 't-20260101-orp5'
    New-Item -ItemType Directory -Path $noStatus -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $noStatus 'thread-1.md'), 'orphan-era thread body', (New-Object System.Text.UTF8Encoding($true)))
    $o5 = Run-Orphan '-MoveToTrash'
    Assert 'A5 thread-no-status dir still there' (Test-Path $noStatus)
    Assert 'A5 output marks it REPORT'           ($o5 -match 'REPORT.*thread-no-status')

    # ---- A6: expiry purge leaves a PURGE journal line ----
    Write-Host 'A6 purge: expired meta expires_at -> purge + PURGE journal line'
    $bin1 = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'meta.json') } | Select-Object -First 1)
    $mPath = Join-Path $bin1.FullName 'meta.json'
    $mJson = [System.IO.File]::ReadAllText($mPath).Replace([string]$meta1.expires_at, '2026-01-01T00:00:00+08:00')
    [System.IO.File]::WriteAllText($mPath, $mJson, (New-Object System.Text.UTF8Encoding($false)))
    $o6 = Run-Orphan '-Purge'
    Assert 'A6 expired trash dir removed'      (-not (Test-Path $bin1.FullName))
    $jTxt = (Get-ChildItem (Join-Path $Root 'logs') -Recurse -Filter 'journal*.log' | Get-Content -Raw) -join ''
    Assert 'A6 PURGE journal line carries original_path' ($jTxt -match ('PURGE.*' + [regex]::Escape($meta1.original_path)))

    # ---- A7: -Empty without -Yes lists only ----
    Write-Host 'A7 empty: -Yes required for real deletion'
    $preCount = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory -ErrorAction SilentlyContinue).Count
    $o7 = Run-Orphan '-Empty'
    Assert 'A7 -Empty without -Yes lists only' ((Get-ChildItem (Join-Path $Root 'post\trash') -Directory -ErrorAction SilentlyContinue).Count -eq $preCount -and $o7 -match 'list only')
    $o7 = Run-Orphan '-Empty -Yes'
    Assert 'A7 -Empty -Yes really deletes'     ((Get-ChildItem (Join-Path $Root 'post\trash') -Directory -ErrorAction SilentlyContinue).Count -eq 0)

    # ---- A8: restore (and refusal when the original path is occupied) ----
    Write-Host 'A8 restore: item back to origin; occupied origin refused'
    $cold2 = Join-Path $Root 'post\cold\msg-20260101-000000-alice-rst8.md'
    New-LetterFile -Path $cold2 -Id msg-20260101-000000-alice-rst8 -Topic t-20260101-orp8 -From alice -To bob
    (Get-Item $cold2).LastWriteTime = (Get-Date).AddMinutes(-2)
    $null = Run-Orphan '-MoveToTrash'
    $rst = $null
    foreach ($d in (Get-ChildItem (Join-Path $Root 'post\trash') -Directory)) {
        $m = [System.IO.File]::ReadAllText((Join-Path $d.FullName 'meta.json')) | ConvertFrom-Json
        if ($m.original_path -eq $cold2) { $rst = [string]$m.trash_id }
    }
    Assert 'A8 trash_id located for restore'   ($null -ne $rst)
    $o8 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'orphan-scan.ps1') -Restore $rst -Root $Root 2>&1 | Out-String
    Assert 'A8 restore puts the item back'     ((Test-Path $cold2) -and $o8 -match 'RESTORED')
    [System.IO.File]::WriteAllText($cold2, 'occupied', (New-Object System.Text.UTF8Encoding($true)))
    $o8 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'orphan-scan.ps1') -Restore $rst -Root $Root 2>&1 | Out-String
    Assert 'A8 occupied origin refused (exit!=0)' ($LASTEXITCODE -ne 0 -and $o8 -match 'refusing')

    # ---- A9: idempotent binning ----
    Write-Host 'A9 idempotency: two consecutive MoveToTrash runs'
    $cold3 = Join-Path $Root 'post\cold\msg-20260101-000000-alice-idm9.md'
    New-LetterFile -Path $cold3 -Id msg-20260101-000000-alice-idm9 -Topic t-20260101-orp9 -From alice -To bob
    (Get-Item $cold3).LastWriteTime = (Get-Date).AddMinutes(-2)
    $null = Run-Orphan '-MoveToTrash'
    $before9 = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory).Count
    $o9 = Run-Orphan '-MoveToTrash'
    $after9 = @(Get-ChildItem (Join-Path $Root 'post\trash') -Directory).Count
    Assert 'A9 second run bins nothing new'    ($before9 -eq $after9 -and $o9 -notmatch '-> binned')

    # ---- A10: a crashed write (dir without meta.json) is swept, not counted ----
    Write-Host 'A10 crash dir: no meta.json -> swept silently'
    New-Item -ItemType Directory -Path (Join-Path $Root 'post\trash\20260101-000000-cras') -Force | Out-Null
    $null = Run-Orphan '-Purge'
    Assert 'A10 empty crash dir swept'         (-not (Test-Path (Join-Path $Root 'post\trash\20260101-000000-cras')))

    # ---- A11: cleanup throttle (scan gated; purge always) ----
    Write-Host 'A11 throttle: second cleanup inside the window does not rescan'
    $lastscan = Join-Path $Root 'post\trash\.lastscan'
    Assert 'A11 .lastscan written by the child scan' (Test-Path $lastscan)
    $lsBefore = (Get-Item $lastscan).LastWriteTime
    $o11 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'core\cleanup.ps1') -Root $Root 2>&1 | Out-String
    $lsAfter = (Get-Item $lastscan).LastWriteTime
    Assert 'A11 second cleanup did not rescan (lastscan untouched)' ($lsBefore -eq $lsAfter)

    # ---- A12: orphan-scan runtime stays trivial on a small tree ----
    Write-Host 'A12 runtime: scan wall-clock on the small tree'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Run-Orphan
    $sw.Stop()
    Assert 'A12 scan completes under 5s on the test tree' ($sw.ElapsedMilliseconds -lt 5000) ('took ' + $sw.ElapsedMilliseconds + 'ms')
    Write-Host ('  (A12 measured: ' + $sw.ElapsedMilliseconds + 'ms - production gate is the sweep-cpu delta, workbuddy measures)')

    Write-Host ''
    Write-Host ('v3 orphan acceptance result: pass=' + $pass + ' fail=' + $fail + '  root: ' + $Root)
    if ($fail -gt 0) { Write-Host ('root KEPT for post-mortem: ' + $Root); exit 1 }
} finally {
    # A1: only a SELF-BUILT root is cleaned up (and only on a green run - a
    # failing run keeps the root for post-mortem, existing behavior).
    if (-not $rootProvided -and -not $Keep -and $script:fail -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fail -gt 0) { exit 1 }
exit 0
