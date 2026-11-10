# run-tests.ps1 - sandbox regression for the AgentsKontakt post office.
#
# Builds a throwaway data root under %TEMP%, seeds two PULL agents (ta / tb)
# and drives the v2 core chain end to end through the REAL scripts:
#   init tree -> deliver -> check -> claim -> heartbeat -> reply ->
#   spoofed-from bounce -> unregistered bounce -> archive gate ->
#   initiator close (gather + dedupe + summary + lock) -> integrity ledger.
#
# No daemon needed: send.ps1 IS the take-out pipeline, route/ps1 deliver and
# PULL cards (wake: TODO) keep the copy in the inbox.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\run-tests.ps1
#   ... -KeepSandbox          # keep the sandbox root for post-mortem
#   ... -Sandbox <dir>        # reuse a specific sandbox root
#
# Exit code 0 = all green, 1 = at least one assertion failed.

param(
  [string]$Sandbox = '',
  [switch]$KeepSandbox
)
$ErrorActionPreference = 'Stop'

# ---- locate the script tree (works flat and layered) ----
$ScriptsDir = Split-Path $PSScriptRoot -Parent
$CoreDir    = if (Test-Path (Join-Path $ScriptsDir 'core\common.ps1')) { Join-Path $ScriptsDir 'core' } else { $ScriptsDir }
$RepoRoot   = Split-Path $ScriptsDir -Parent

# ---- sandbox setup ----
if (-not $Sandbox) { $Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('ak-regress-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$Sandbox = $Sandbox.TrimEnd('\')
if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Host ('  [ok]   ' + $Name)
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  :: ' + $Detail }))
    }
}

function Invoke-Post {
    # Run one post-office script against the sandbox; return @{ out; code }.
    # (the splat variable must not be named $Args - that is a reserved
    # automatic variable and splatting it silently drops the arguments)
    param([string]$Script, [string[]]$PostArgs = @())
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @PostArgs -Root $Sandbox 2>&1 | Out-String
    return @{ out = $out; code = $LASTEXITCODE }
}

$script:Rnd = ''
function New-Rand { $script:Rnd = ''; 1..4 | ForEach-Object { $script:Rnd += '{0:x}' -f (Get-Random -Maximum 16) }; return $script:Rnd }

function New-Letter {
    # Compose a protocol letter in <agent>'s outbox; return the file path.
    param([string]$From, [string]$To, [string]$Type = 'request', [string]$Subject = '', [string]$InReplyTo = '', [string]$Body = 'test body', [string]$Topic = '')
    $id    = 'msg-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $From + '-' + (New-Rand)
    if (-not $Topic) { $Topic = 't-' + (Get-Date -Format 'yyyyMMdd') + '-' + (New-Rand) }
    $nl = "`r`n"
    $fm = '---' + $nl +
          'id: ' + $id + $nl +
          'topic: ' + $topic + $nl +
          'from: ' + $From + $nl +
          'to: ' + $To + $nl +
          'type: ' + $Type + $nl
    if ($Subject)    { $fm += 'subject: ' + $Subject + $nl }
    if ($InReplyTo)  { $fm += 'in_reply_to: ' + $InReplyTo + $nl }
    $fm += 'created: ' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz') + $nl +
           'state: open' + $nl +
           '---' + $nl + $nl + $Body + $nl
    $dir  = Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') $From) 'outbox'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ($id + '.md')
    [System.IO.File]::WriteAllText($path, $fm, (New-Object System.Text.UTF8Encoding($false)))
    return @{ path = $path; id = $id; topic = $topic }
}

function Get-SidecarValue {
    param([string]$MessagePath, [string]$Key)
    $side = [System.IO.Path]::ChangeExtension($MessagePath, '.status')
    if (-not (Test-Path -LiteralPath $side)) { return '' }
    foreach ($ln in [System.IO.File]::ReadAllLines($side)) {
        if ($ln -match ('^' + [regex]::Escape($Key) + ':\s*(.*)$')) { return $Matches[1] }
    }
    return ''
}

Write-Host ('sandbox: ' + $Sandbox)
Write-Host ('scripts: ' + $ScriptsDir + $(if ($CoreDir -ne $ScriptsDir) { '  (layered: core)' }))

# ---- seed: registry cards + templates ----
$regDir = Join-Path $Sandbox 'registry'
New-Item -ItemType Directory -Path $regDir -Force | Out-Null
foreach ($a in @('ta', 'tb')) {
    $card = '---' + "`r`n" +
            'name: ' + $a + "`r`n" +
            'inbox: mailboxes\' + $a + '\inbox\' + "`r`n" +
            'wake: TODO' + "`r`n" +
            'model: test-model' + "`r`n" +
            '---' + "`r`n`r`n" + 'sandbox regression agent.' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $regDir ($a + '.md')), $card, (New-Object System.Text.UTF8Encoding($false)))
}
$sbxTemplates = Join-Path $Sandbox 'templates'
New-Item -ItemType Directory -Path $sbxTemplates -Force | Out-Null
Copy-Item (Join-Path $RepoRoot 'templates\*') $sbxTemplates -Recurse -Force

Write-Host ''
Write-Host 'T0 init tree'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'init.ps1')
Assert 'init exits 0'                      ($r.code -eq 0) $r.out
foreach ($a in @('ta', 'tb')) {
    foreach ($d in @('inbox', 'outbox', 'processing', 'sent', 'notes')) {
        Assert ('five-area mailbox: ' + $a + '\' + $d) (Test-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') $a) $d))
    }
}

Write-Host 'T1 deliver (v3): request ta -> tb creates the topic + chain copy + master'
$req = New-Letter -From 'ta' -To 'tb' -Type 'request' -Subject 'regression request' -Body 'please answer with ACCEPTANCE-OK'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $req.path)
$chainCopy = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'inbox') ($req.topic + '.chain.md')
$master    = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'sent') ($req.id + '.md')
$threadStatus = Join-Path (Join-Path (Join-Path $Sandbox 'post') 'threads') ($req.topic + '\status.json')
Assert 'send exits 0 (DELIVERED)'          ($r.code -eq 0 -and $r.out -match 'DELIVERED') $r.out
Assert 'v3 thread created (status.json)'   (Test-Path $threadStatus)
Assert 'thread state=pending'              ((Get-Content $threadStatus -Raw | ConvertFrom-Json).state -eq 'pending')
Assert 'chain copy in recipient inbox'     (Test-Path $chainCopy)
Assert 'master in sender sent area'        (Test-Path $master)
Assert 'master status DELIVERED'           ((Get-SidecarValue -MessagePath $master -Key 'status') -eq 'DELIVERED')
Assert 'receipt sys-mail in sender inbox'  (@(Get-ChildItem (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'inbox') -Filter 'sys-*.md' -ErrorAction SilentlyContinue).Count -ge 1)

Write-Host 'T2 PULL check + claim (state flip, no move) + heartbeat (v3)'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'mail-check.ps1') -PostArgs @('-Agent', 'tb')
Assert 'mail-check reports TOPIC (exit 1)' ($r.code -eq 1 -and $r.out -match 'TOPIC') ('exit=' + $r.code + ' ' + $r.out)
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'claim.ps1') -PostArgs @('-File', $chainCopy)
Assert 'claim flips state to processing'   ($r.code -eq 0 -and ((Get-Content $threadStatus -Raw | ConvertFrom-Json).state -eq 'processing')) $r.out
Assert 'chain copy stayed in inbox (no move)' (Test-Path $chainCopy)
$hbBefore = (Get-Content $threadStatus -Raw | ConvertFrom-Json).last_heartbeat
Start-Sleep -Milliseconds 1100   # heartbeat timestamps are second-granular
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'progress.ps1') -PostArgs @('-Topic', $req.topic, '-Note', 'regression heartbeat')
Assert 'heartbeat refreshes last_heartbeat' ((Get-Content $threadStatus -Raw | ConvertFrom-Json).last_heartbeat -ne $hbBefore)

Write-Host 'T3 answer (v3): tb answers - answered + zero traces on tb + chain to ta'
$rep = New-Letter -From 'tb' -To 'ta' -Type 'reply' -InReplyTo $req.id -Topic $req.topic -Body 'ACCEPTANCE-OK' -Kind 'answer'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $rep.path)
$chainInTa = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'inbox') ($req.topic + '.chain.md')
Assert 'answer delivered, state=answered'  ($r.code -eq 0 -and $r.out -match 'DELIVERED' -and ((Get-Content $threadStatus -Raw | ConvertFrom-Json).state -eq 'answered')) $r.out
Assert 'chain copy refreshed in ta inbox (contains the answer)' ((Test-Path $chainInTa) -and ((Get-Content $chainInTa -Raw) -match 'ACCEPTANCE-OK'))
Assert 'tb left zero traces (chain copy cleared)' (-not (Test-Path $chainCopy))
Assert 'copies trace kept (tb cleared_at set)' ([string]((Get-Content $threadStatus -Raw | ConvertFrom-Json).copies.tb.cleared_at) -ne '')
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'mail-status.ps1') -PostArgs @('-Topic', $req.topic)
Assert 'mail-status prints the STATE line' ($r.code -eq 0 -and $r.out -match 'STATE') $r.out

Write-Host 'T4 gate: spoofed from is returned with a reason'
$spoof = New-Letter -From 'ta' -To 'tb' -Type 'request' -Subject 'spoof test'
# rewrite the envelope sender to someone else while keeping the outbox owner
$bytes = [System.IO.File]::ReadAllText($spoof.path).Replace('from: ta', 'from: postmaster')
[System.IO.File]::WriteAllText($spoof.path, $bytes, (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $spoof.path)
$spoofMaster = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'sent') ($spoof.id + '.md')
Assert 'spoofed mail RETURNED (exit 0)'    ($r.code -eq 0 -and $r.out -match 'RETURNED.*spoofed') $r.out
Assert 'returned master parked in sent'    ((Get-SidecarValue -MessagePath $spoofMaster -Key 'status') -eq 'RETURNED')
Assert 'bounce reason present'             ((Get-SidecarValue -MessagePath $spoofMaster -Key 'reason') -match 'spoofed from')

Write-Host 'T5 gate: unregistered recipient is returned'
$ghost = New-Letter -From 'ta' -To 'ghost' -Type 'request' -Subject 'ghost test'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $ghost.path)
Assert 'unregistered recipient RETURNED'   ($r.code -eq 0 -and $r.out -match 'RETURNED.*not registered') $r.out

Write-Host 'T6 archive gate: non-initiator close is denied'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'close.ps1') -PostArgs @('-Topic', $req.topic, '-Agent', 'tb')
Assert 'non-initiator close DENIED (exit 1)' ($r.code -eq 1 -and $r.out -match 'DENIED') $r.out
$tbInbox = Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'inbox'
Assert 'ARCHIVE-DENIED sys-mail in tb inbox' (@(Get-ChildItem $tbInbox -Filter 'sys-*.md' -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match 'ARCHIVE-DENIED' }).Count -ge 1)

Write-Host 'T7 archive by initiator (v3): chain + status + summary + JSONL + lockdown'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'close.ps1') -PostArgs @('-Topic', $req.topic, '-Agent', 'ta')
$d = (Get-Date -Format 'yyyy'), (Get-Date -Format 'MM'), (Get-Date -Format 'dd')
$archDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'archive') 'ta') $d[0]) $d[1]) $d[2]) $req.topic
Assert 'close exits 0 (CLOSED)'            ($r.code -eq 0 -and $r.out -match 'CLOSED') $r.out
Assert 'archive topic dir created'         (Test-Path $archDir)
Assert 'thread chain + summary archived'   ((@(Get-ChildItem $archDir -Filter 'thread-*.md')).Count -ge 1 -and (Test-Path (Join-Path $archDir 'summary.md')))
Assert 'status.json archived with the chain' (Test-Path (Join-Path $archDir 'status.json'))
Assert 'threads dir emptied (no orphans)'  (-not (Test-Path $threadStatus))
Assert 'both inboxes cleared of the chain copy' (-not (Test-Path $chainInTa) -and -not (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'inbox') ($req.topic + '.chain.md'))))
$summary = Join-Path $archDir 'summary.md'
Assert 'summary front-matter from=ta'      ((Test-Path $summary) -and ((Get-Content $summary -Raw) -match 'from: ta'))
Assert 'global index has the topic'        ((Get-Content (Join-Path (Join-Path $Sandbox 'archive') 'index.md') -Raw) -match [regex]::Escape($req.topic))
Assert 'JSONL index has the topic'         ((Get-Content (Join-Path (Join-Path $Sandbox 'archive') 'index.jsonl') -Raw) -match [regex]::Escape($req.topic))
$lockProbe = Join-Path $archDir 'thread-1.md'
$locked = $false
try { $fs = [System.IO.File]::Open($lockProbe, 'Append', 'Write'); $fs.Close() } catch { $locked = $true }
Assert 'archived files are read-only'      $locked

Write-Host 'T8 integrity ledger passes on the fresh archive'
$r = Invoke-Post -Script (Join-Path $CoreDir 'integrity.ps1')
Assert 'integrity exits 0 (no tamper)'     ($r.code -eq 0 -and $r.out -match 'tampered=0') $r.out

Write-Host 'T9 log hygiene: size rotation + mirror expiry'
$logDir = Join-Path (Join-Path $Sandbox 'logs') 'ta'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$bigJournal = Join-Path $logDir 'journal.log'
[System.IO.File]::WriteAllText($bigJournal, ('x' * (3 * 1MB)))   # 3MB > default 2MB threshold
$mirrorDir = Join-Path (Join-Path $Sandbox 'logs') 'ta-mirror'
New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
$oldStream = Join-Path $mirrorDir 'stream-oldsession.jsonl'
[System.IO.File]::WriteAllText($oldStream, 'stale mirror')
(Get-Item -LiteralPath $oldStream).LastWriteTime = (Get-Date).AddDays(-10)
$newStream = Join-Path $mirrorDir 'stream-livesession.jsonl'
[System.IO.File]::WriteAllText($newStream, 'active mirror')
$r = Invoke-Post -Script (Join-Path $CoreDir 'cleanup.ps1')
Assert 'cleanup exits 0'                   ($r.code -eq 0) $r.out
Assert 'oversized journal rotated away'    (-not (Test-Path $bigJournal))
$rotations = @(Get-ChildItem -LiteralPath $logDir -Filter 'journal-*.log' -ErrorAction SilentlyContinue)
Assert 'rotation file present'             ($rotations.Count -ge 1 -and $rotations[0].Length -ge (2 * 1MB))
Assert 'expired mirror deleted'            (-not (Test-Path $oldStream))
Assert 'live mirror kept'                  (Test-Path $newStream)

# ---- T10: v3 selftest (r4.1 §7-3) - full state-machine chain in a temp root ----
# A2 (t-20261111): this used to go through Invoke-Post, which unconditionally
# appends -Root $Sandbox. The selftest accepts -Root, ran its whole chain
# INSIDE the regression sandbox, and its finally block deleted the sandbox on
# a green run (it had no rootProvided guard). Green-but-poisoned: nothing
# after T10 touched $Sandbox, so it stayed invisible until T12 arrived. Call
# it directly like T11 - the selftest builds and cleans its own throwaway root.
Write-Host 'T10 v3 selftest: state machine + neutral docs full chain'
$out10 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'tests\test-v3-selftest.ps1') 2>&1 | Out-String
$code10 = $LASTEXITCODE
# A2 (t-20261107-ix07): parse the pass/fail counts from the output instead of
# hardcoding one - the assertion count grows with every new case and a stale
# number in the name is exactly the "green but wrong" shape workbuddy flagged.
$st10 = $null
if ($out10 -match 'pass=(\d+)\s+fail=(\d+)') { $st10 = @{ pass = [int]$Matches[1]; fail = [int]$Matches[2] } }
Assert 'v3 selftest exits 0, all assertions green' ($code10 -eq 0 -and $st10 -and $st10.fail -eq 0 -and $st10.pass -gt 0) $out10

# ---- T11: v3 orphan recycle-station acceptance (n5w8 A1-A12) ----
# A2: this call used to go through Invoke-Post, which unconditionally appends
# -Root $Sandbox - and the orphan test's finally block deleted that external
# root on a green run, taking the whole regression sandbox with it (the
# run-51/0-but-exit-1 P0). The test builds its own throwaway root: call it
# directly, with no -Root injection.
Write-Host 'T11 v3 orphan acceptance: scan + trash + purge + restore'
$out11 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir 'tests\test-v3-orphan.ps1') 2>&1 | Out-String
$code11 = $LASTEXITCODE
$st11 = $null
if ($out11 -match 'pass=(\d+)\s+fail=(\d+)') { $st11 = @{ pass = [int]$Matches[1]; fail = [int]$Matches[2] } }
Assert 'v3 orphan acceptance exits 0, all assertions green' ($code11 -eq 0 -and $st11 -and $st11.fail -eq 0 -and $st11.pass -gt 0) $out11

# ---- T12: audit-notify - findings -> AUDIT sys mail, strictly-once ledger ----
# ta/tb seed cards are wake:TODO with no pull field and no liveness line, so
# fail-liveness + fail-pull-missing (plus warn-no-poll-journal) fire
# deterministically - no Task Scheduler or TCP probes involved. The heal step
# rewrites ta's card with a pull exemption, exactly the field a compliant
# card would carry.
Write-Host 'T12 audit-notify: sys mail + strict-once dedup + healed-ledger clear'
$auditSubj = [regex]::Escape('subject: AUDIT ')
$taInbox = Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'inbox'
$r = Invoke-Post -Script (Join-Path $CoreDir 'audit-notify.ps1')
Assert 'audit-notify exits 0' ($r.code -eq 0) $r.out
$taSys1 = @(Get-ChildItem $taInbox -Filter 'sys-*.md' -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw) -match ($auditSubj + 'ta') })
Assert 'audit sys mail delivered to ta' ($taSys1.Count -ge 1) $r.out
Assert 'notify ledger created' (Test-Path (Join-Path $Sandbox 'post\audit-notify.json'))
$r = Invoke-Post -Script (Join-Path $CoreDir 'audit-notify.ps1')
$taSys2 = @(Get-ChildItem $taInbox -Filter 'sys-*.md' |
    Where-Object { (Get-Content $_.FullName -Raw) -match ($auditSubj + 'ta') })
Assert 'strictly once: second run sends no new mail' ($taSys2.Count -eq $taSys1.Count) $r.out
# heal: register the pull exemption the way a compliant card would
$cardPath = Join-Path $regDir 'ta.md'
$cardText = (Get-Content $cardPath -Raw).Replace('model: test-model', "model: test-model`r`npull: none - test-exempt")
[System.IO.File]::WriteAllText($cardPath, $cardText, (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Post -Script (Join-Path $CoreDir 'audit-notify.ps1')
$taSys3 = @(Get-ChildItem $taInbox -Filter 'sys-*.md' |
    Where-Object { (Get-Content $_.FullName -Raw) -match ($auditSubj + 'ta') })
Assert 'healed: no new mail after pull registered' ($taSys3.Count -eq $taSys1.Count) $r.out
$ledText = Get-Content (Join-Path $Sandbox 'post\audit-notify.json') -Raw
Assert 'healed key cleared from ledger' ($ledText -notmatch [regex]::Escape('ta|fail-pull-missing')) $ledText
Assert 'unhealed keys stay in ledger' ($ledText -match [regex]::Escape('ta|fail-liveness')) $ledText
# CLI regression after the lib refactor: renderer keeps exit codes + output
$ra = Invoke-Post -Script (Join-Path $ScriptsDir 'registry-audit.ps1')
Assert 'registry-audit CLI exit 1 with FAIL present' ($ra.code -eq 1) $ra.out
Assert 'registry-audit CLI renders [FAIL] line' ($ra.out -match '\[FAIL\]') $ra.out

# ---- summary ----
Write-Host ''
Write-Host ('result: pass=' + $script:Pass + ' fail=' + $script:Fail)
if ($script:Fail -gt 0) {
    Write-Host ('sandbox KEPT for post-mortem: ' + $Sandbox)
    exit 1
}
if ($KeepSandbox) { Write-Host ('sandbox kept: ' + $Sandbox) }
elseif (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }   # A2: a test may legitimately have consumed it already
exit 0
