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

Write-Host 'T1 deliver: request ta -> tb (copy-delivery + master + receipt)'
$req = New-Letter -From 'ta' -To 'tb' -Type 'request' -Subject 'regression request' -Body 'please answer with ACCEPTANCE-OK'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $req.path)
$copyPath = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'inbox') ($req.id + '.md')
$master   = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'sent') ($req.id + '.md')
Assert 'send exits 0 (DELIVERED)'          ($r.code -eq 0 -and $r.out -match 'DELIVERED') $r.out
Assert 'copy in recipient inbox'           (Test-Path $copyPath)
Assert 'master in sender sent area'        (Test-Path $master)
Assert 'master status DELIVERED'           ((Get-SidecarValue -MessagePath $master -Key 'status') -eq 'DELIVERED')
Assert 'manifest has both copies'          ((@(Get-Content (Join-Path (Join-Path (Join-Path $Sandbox 'post') 'manifest') ($req.topic + '.manifest')) -ErrorAction SilentlyContinue)).Count -ge 2)
Assert 'receipt sys-mail in sender inbox'  (@(Get-ChildItem (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'inbox') -Filter 'sys-*.md' -ErrorAction SilentlyContinue).Count -ge 1)

Write-Host 'T2 PULL check + claim + heartbeat'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'mail-check.ps1') -PostArgs @('-Agent', 'tb')
Assert 'mail-check reports mail (exit 1)'  ($r.code -eq 1) ('exit=' + $r.code + ' ' + $r.out)
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'claim.ps1') -PostArgs @('-File', $copyPath)
Assert 'claim moves into processing'       ($r.code -eq 0 -and (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'processing') ($req.id + '.md')))) $r.out
$claimed = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'processing') ($req.id + '.md')
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'progress.ps1') -PostArgs @('-File', $claimed, '-Note', 'regression heartbeat')
Assert 'heartbeat sidecar written'         (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'processing') ($req.id + '.progress')))

Write-Host 'T3 reply tb -> ta (role flip, requester master flips REPLIED)'
$rep = New-Letter -From 'tb' -To 'ta' -Type 'reply' -InReplyTo $req.id -Topic $req.topic -Body 'ACCEPTANCE-OK'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'send.ps1') -PostArgs @('-File', $rep.path)
$replyInTa = Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'ta') 'inbox') ($rep.id + '.md')
Assert 'reply delivered to ta inbox'       ($r.code -eq 0 -and $r.out -match 'DELIVERED' -and (Test-Path $replyInTa)) $r.out
Assert 'requester master status REPLIED'   ((Get-SidecarValue -MessagePath $master -Key 'status') -eq 'REPLIED')
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'mail-status.ps1') -PostArgs @('-Topic', $req.topic)
Assert 'mail-status runs (exit 0)'         ($r.code -eq 0) $r.out

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

Write-Host 'T7 close by initiator: gather + dedupe + summary + lockdown'
$r = Invoke-Post -Script (Join-Path $ScriptsDir 'close.ps1') -PostArgs @('-Topic', $req.topic, '-Agent', 'ta')
$d = (Get-Date -Format 'yyyy'), (Get-Date -Format 'MM'), (Get-Date -Format 'dd')
$archDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'archive') 'ta') $d[0]) $d[1]) $d[2]) $req.topic
Assert 'close exits 0 (CLOSED)'            ($r.code -eq 0 -and $r.out -match 'CLOSED') $r.out
Assert 'archive topic dir created'         (Test-Path $archDir)
Assert 'request + reply + summary gathered' ((@(Get-ChildItem $archDir -Filter '*.md')).Count -ge 3)
Assert 'sender master deduped away'        (-not (Test-Path $master))
Assert 'responder master deduped away'     (-not (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $Sandbox 'mailboxes') 'tb') 'sent') ($rep.id + '.md'))))
$summary = Join-Path $archDir 'summary.md'
Assert 'summary front-matter from=ta'      ((Test-Path $summary) -and ((Get-Content $summary -Raw) -match 'from: ta'))
Assert 'global index has the topic'        ((Get-Content (Join-Path (Join-Path $Sandbox 'archive') 'index.md') -Raw) -match [regex]::Escape($req.topic))
$lockProbe = Join-Path $archDir ($req.id + '.md')
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

# ---- summary ----
Write-Host ''
Write-Host ('result: pass=' + $script:Pass + ' fail=' + $script:Fail)
if ($script:Fail -gt 0) {
    Write-Host ('sandbox KEPT for post-mortem: ' + $Sandbox)
    exit 1
}
if ($KeepSandbox) { Write-Host ('sandbox kept: ' + $Sandbox) }
else { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
exit 0
