param(
  [string]$Root = '',
  [switch]$Keep,
  [string]$Only = ''
)
$ErrorActionPreference = 'Continue'   # child-process stderr must not abort the run; Assert owns pass/fail

# v3 --selftest (r4.1 §7-3): builds a throwaway data root in %TEMP%, runs the
# full v3 lifecycle end to end (open -> claim -> answer -> follow-up -> answer
# -> archive) plus the incident/defense paths, and asserts every state-machine
# rule from docs\协议修订案-v3-状态机与中立文档.md (r4.1). The dev tree stays
# data-free: everything happens under $Root (a fresh temp dir unless -Root).
#
# Covers the six acceptance paths workbuddy announced for phase one:
#   P1 --selftest full chain (this script IS that chain, temp root, zero dev data)
#   P2 anti-overwrite refusal path (same id twice -> master kept + quarantine + alarm)
#   P3 pre-check BOM stripping (a BOM-carrying compliant letter is NOT invalid)
#   P4 copies trace (copies survive the copy clearing: delivered_at/cleared_at)
#   P5 backfill criterion (a missing _index.md row is recovered; set-equality)
#   P6 legacy split (a status.json-less in-flight topic closes via legacy branch)
#
# Entry points: tests\run-tests.ps1 invokes this; send.ps1/claim.ps1/archive.ps1
# accept -Selftest and forward here (see the -Only filter).

$scriptRoot = Split-Path $PSScriptRoot -Parent   # scripts\
# A1 (t-20261111): the finally block deletes $Root on a green run. When the
# caller passed -Root (run-tests.ps1 T10 used to inject its sandbox here via
# Invoke-Post) that deleted the EXTERNAL root - same P0 shape the orphan test
# fixed. Guard: only a self-built root may be cleaned up.
$rootProvided = [bool]$Root
if (-not $Root) {
    $Root = Join-Path ([System.IO.Path]::GetTempPath()) ('ak-v3-selftest-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Maximum 9999))
}
$pass = 0; $fail = 0
function Assert {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ('  [ok]   ' + $Name) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' :: ' + $Detail })) }
}
function New-TestLetter {
    # Write a v3 envelope letter into an agent's outbox (UTF-8 with BOM).
    param([string]$Root, [string]$From, [string]$To, [string]$Topic,
          [string]$Type, [string]$Subject, [string]$Body, [string]$InReplyTo = '', [string]$Kind = '')
    $id = 'msg-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $From + '-' + (-join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ }))
    $nl = "`r`n"
    $fm = '---' + $nl + 'id: ' + $id + $nl + 'topic: ' + $Topic + $nl +
          'subject: ' + $Subject + $nl + 'from: ' + $From + $nl + 'to: ' + $To + $nl +
          'model: test-model' + $nl + 'type: ' + $Type + $nl
    if ($InReplyTo) { $fm += 'in_reply_to: ' + $InReplyTo + $nl }
    if ($Kind) { $fm += 'kind: ' + $Kind + $nl }
    $fm += 'created: ' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz') + $nl + 'state: open' + $nl + '---' + $nl + $nl + $Body + $nl
    $out = Join-Path (Join-Path (Join-Path $Root 'mailboxes') $From) 'outbox'
    $p = Join-Path $out ($id + '.md')
    [System.IO.File]::WriteAllText($p, $fm, (New-Object System.Text.UTF8Encoding($true)))
    return $p
}

Write-Host ('v3 selftest root: ' + $Root)

# ---- stage the throwaway root ----
foreach ($d in @('registry','mailboxes','archive','logs','logs\routed','templates','config',
                 'mailboxes\alice\inbox','mailboxes\alice\outbox','mailboxes\alice\processing','mailboxes\alice\sent','mailboxes\alice\notes',
                 'mailboxes\bob\inbox','mailboxes\bob\outbox','mailboxes\bob\processing','mailboxes\bob\sent','mailboxes\bob\notes')) {
    New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
}
$card = '---' + "`r`n" + 'name: {0}' + "`r`n" + 'inbox: mailboxes\{0}\inbox' + "`r`n" + 'model: test-model' + "`r`n" + 'wake: TODO' + "`r`n" + '---' + "`r`n"
foreach ($a in @('alice', 'bob')) {
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'registry') ($a + '.md')), ($card -f $a), (New-Object System.Text.UTF8Encoding($true)))
}
Copy-Item -Path (Join-Path (Split-Path $scriptRoot -Parent) 'templates\*') -Destination (Join-Path $Root 'templates') -Force

$env:MAILBOX_ROOT = $Root
$send   = Join-Path $scriptRoot 'send.ps1'
$claim  = Join-Path $scriptRoot 'claim.ps1'
$arch   = Join-Path $scriptRoot 'archive.ps1'
$threads = Join-Path $Root 'post\threads'
function Invoke-Send {
    param([string]$LetterPath)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $send -File $LetterPath -Root $Root 2>&1 | Out-String
    return $out
}

try {
    if ($Only -and $Only -ne 'all') { Write-Host ('selftest -Only ' + $Only + ' is accepted for entry-point compat; running the full chain') }

    # ---- T1: A opens a topic (P3 covered: the letter carries a BOM) ----
    Write-Host 'T1 open: alice -> bob request'
    $l1 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst1 -Type request -Subject 'selftest opening question' -Body 'First question body.'
    $o1 = Invoke-Send -LetterPath $l1
    Assert 'T1 topic created (status.json pending)'   (Test-Path (Join-Path $threads 't-20260101-tst1\status.json'))
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T1 state=pending + delivered_at set'      ($st.state -eq 'pending' -and [string]$st.delivered_at -ne '')
    Assert 'T1 thread-1.md carries turn 1'            (Test-Path (Join-Path $threads 't-20260101-tst1\thread-1.md') -PathType Leaf)
    Assert 'T1 chain copy in bob inbox'               (Test-Path (Join-Path $Root 'mailboxes\bob\inbox\t-20260101-tst1.chain.md'))
    Assert 'T1 master full text in alice sent (A3: phase one keeps full body)' (Test-Path (Join-Path (Join-Path $Root 'mailboxes\alice\sent') (Split-Path $l1 -Leaf)) -PathType Leaf)
    Assert 'T1 letter had BOM and was delivered (P3)' ($o1 -match 'DELIVERED')

    # ---- T2: B claims the chain copy (state machine, no physical move) ----
    Write-Host 'T2 claim: bob claims the chain copy'
    $chainInBob = Join-Path $Root 'mailboxes\bob\inbox\t-20260101-tst1.chain.md'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $claim -File $chainInBob -Root $Root 2>&1
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T2 state=processing'                      ($st.state -eq 'processing')
    Assert 'T2 copy stayed in bob inbox (no move)'    (Test-Path $chainInBob)
    Assert 'T2 last_heartbeat refreshed'              ([string]$st.last_heartbeat -ne '')

    # ---- T2b: round-robin gate - a question while processing must be RETURNED ----
    Write-Host 'T2b round-robin: question during processing is refused'
    $lq = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst1 -Type request -Subject 'follow-up too early' -Body 'early question' -Kind question
    $oq = Invoke-Send -LetterPath $lq
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T2b question during processing RETURNED'  ($oq -match 'RETURNED')
    Assert 'T2b state still processing'               ($st.state -eq 'processing')

    # ---- T3: B answers (kind=answer) - zero traces on B, copies trace kept (P4) ----
    Write-Host 'T3 answer: bob replies'
    $l2 = New-TestLetter -Root $Root -From bob -To alice -Topic t-20260101-tst1 -Type reply -Subject 'answer' -Body 'Here is the answer.' -InReplyTo ([System.IO.Path]::GetFileNameWithoutExtension($l1))
    $o2 = Invoke-Send -LetterPath $l2
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T3 state=answered'                        ($st.state -eq 'answered')
    Assert 'T3 chain copy delivered to alice inbox'   (Test-Path (Join-Path $Root 'mailboxes\alice\inbox\t-20260101-tst1.chain.md'))
    $aliceChain = Get-Content (Join-Path $Root 'mailboxes\alice\inbox\t-20260101-tst1.chain.md') -Raw
    Assert 'T3 alice chain contains the answer turn'  ($aliceChain -match 'Here is the answer')
    Assert 'T3 bob inbox/processing cleared (zero traces)' (-not (Test-Path (Join-Path $Root 'mailboxes\bob\inbox\t-20260101-tst1.chain.md')) -and -not (Test-Path (Join-Path $Root 'mailboxes\bob\processing\t-20260101-tst1.chain.md')))
    $copies = $st.copies
    Assert 'T4 copies trace: bob has cleared_at, alice has delivered_at' ($copies -and $copies.bob -and [string]$copies.bob.cleared_at -ne '' -and $copies.alice -and [string]$copies.alice.delivered_at -ne '')

    # ---- T3b: answer from a non-recipient is refused ----
    Write-Host 'T3b role gate: answer from alice (initiator) refused'
    $l3 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst1 -Type reply -Subject 'bogus answer' -Body 'not mine to answer' -Kind answer
    $o3 = Invoke-Send -LetterPath $l3
    Assert 'T3b role mismatch RETURNED'               ($o3 -match 'RETURNED')

    # ---- T4: A follows up (kind=question) - back to pending ----
    Write-Host 'T4 follow-up: alice asks again'
    $l4 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst1 -Type request -Subject 'follow-up' -Body 'One more thing.' -Kind question
    $o4 = Invoke-Send -LetterPath $l4
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T4 state=pending after follow-up'         ($st.state -eq 'pending')
    Assert 'T4 chain copy refreshed in bob inbox'     (Test-Path $chainInBob)
    $bobChain = Get-Content $chainInBob -Raw
    Assert 'T4 bob chain carries the follow-up turn'  ($bobChain -match 'One more thing')

    # ---- T5: B answers again -> answered ----
    Write-Host 'T5 answer 2: bob replies again'
    $l5 = New-TestLetter -Root $Root -From bob -To alice -Topic t-20260101-tst1 -Type reply -Subject 'answer 2' -Body 'Second answer.' -InReplyTo ([System.IO.Path]::GetFileNameWithoutExtension($l1))
    $null = Invoke-Send -LetterPath $l5
    $st = Get-Content (Join-Path $threads 't-20260101-tst1\status.json') -Raw | ConvertFrom-Json
    Assert 'T5 state=answered again'                  ($st.state -eq 'answered')

    # ---- T6: A archives (kind=archive-note) - terminal, both mailboxes cleared (P1 end) ----
    Write-Host 'T6 archive: alice closes with an archive note'
    $l6 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst1 -Type request -Subject 'archive note' -Body 'Closing this topic.' -Kind 'archive-note'
    $o6 = Invoke-Send -LetterPath $l6
    Assert 'T6 threads dir emptied (no orphans)'      (-not (Test-Path (Join-Path $threads 't-20260101-tst1\status.json')))
    $archDir = Join-Path $Root 'archive\alice\2026'
    Assert 'T6 archive dir exists with chain'         ((Get-ChildItem $archDir -Recurse -Filter 'thread-1.md' -ErrorAction SilentlyContinue).Count -ge 1)
    $archTopic = (Get-ChildItem $archDir -Recurse -Directory -Filter 't-20260101-tst1' | Select-Object -First 1)
    Assert 'T6 status.json moved into archive'        ($null -ne $archTopic -and (Test-Path (Join-Path $archTopic.FullName 'status.json')))
    Assert 'T6 summary.md generated'                  ($null -ne $archTopic -and (Test-Path (Join-Path $archTopic.FullName 'summary.md')))
    Assert 'T6 both inboxes cleared'                  (-not (Test-Path (Join-Path $Root 'mailboxes\alice\inbox\t-20260101-tst1.chain.md')) -and -not (Test-Path (Join-Path $Root 'mailboxes\bob\inbox\t-20260101-tst1.chain.md')))
    $jsonl = Join-Path $Root 'archive\index.jsonl'
    $jsonlHit = $false
    if (Test-Path $jsonl) { foreach ($ln in [System.IO.File]::ReadAllLines($jsonl)) { if ($ln -match 't-20260101-tst1') { $jsonlHit = $true } } }
    Assert 'T6 JSONL record written (both parties queryable)' $jsonlHit
    $ro = $archTopic.GetFiles() | Where-Object { $_.Name -eq 'thread-1.md' }
    Assert 'T6 archive lockdown (read-only)'          ($ro -and $ro.IsReadOnly)

    # ---- T7: anti-overwrite (P2) - same id twice -> master kept, newcomer quarantined ----
    Write-Host 'T7 anti-overwrite: duplicate id into sent is blocked'
    $l7 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst2 -Type request -Subject 'dup probe' -Body 'dup probe body.'
    $null = Invoke-Send -LetterPath $l7     # first delivery: master lands in sent
    $masterPath = Join-Path $Root ('mailboxes\alice\sent\' + (Split-Path $l7 -Leaf))
    Assert 'T7 first master in sent'                  (Test-Path $masterPath)
    $before = (Get-Item $masterPath).LastWriteTimeUtc.Ticks
    $l7b = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst2 -Type request -Subject 'dup probe' -Body 'dup probe body.'
    # force the SAME id: rewrite the fresh letter with the first letter's id
    $txt = [System.IO.File]::ReadAllText($l7b)
    $origIdLine = ([System.IO.File]::ReadAllText($l7b) -split "`r`n" | Where-Object { $_ -match '^id:' })
    $rx = 'id: msg-[0-9\-]+-alice-[a-z0-9]+'
    $txt = $txt -replace $rx, ('id: ' + [System.IO.Path]::GetFileNameWithoutExtension($l7))
    [System.IO.File]::WriteAllText($l7b, $txt, (New-Object System.Text.UTF8Encoding($true)))
    $o7 = Invoke-Send -LetterPath $l7b
    $after = (Get-Item $masterPath).LastWriteTimeUtc.Ticks
    Assert 'T7 master kept (untouched)'               ($before -eq $after)
    Assert 'T7 OVERWRITE-BLOCKED reported'            ($o7 -match 'OVERWRITE-BLOCKED') $o7
    Assert 'T7 newcomer quarantined in cold'          ((Get-ChildItem (Join-Path $Root 'post\cold') -Filter '*dup*').Count -ge 1)

    # ---- T9: legacy split (P6) - a v2-era in-flight topic closes via legacy branch ----
    Write-Host 'T9 legacy split: status.json-less topic closes via archive-legacy'
    $legacyId = 'msg-20260101-000000-alice-leg0'
    $legacyFm = '---' + "`r`n" + 'id: ' + $legacyId + "`r`n" + 'topic: t-20260101-leg0' + "`r`n" +
        'subject: legacy era request' + "`r`n" + 'from: alice' + "`r`n" + 'to: bob' + "`r`n" +
        'type: request' + "`r`n" + 'created: 2026-01-01T00:00:00+08:00' + "`r`n" + 'state: open' + "`r`n" + '---' + "`r`n`r`n" + 'legacy body' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\bob\inbox') ($legacyId + '.md')), $legacyFm, (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') ($legacyId + '.md')), $legacyFm, (New-Object System.Text.UTF8Encoding($true)))
    $ol = & powershell -NoProfile -ExecutionPolicy Bypass -File $arch -Topic t-20260101-leg0 -Agent alice -Root $Root 2>&1 | Out-String
    Assert 'T9 legacy close succeeded (gather close)' ($ol -match 'CLOSED topic t-20260101-leg0') $ol
    Assert 'T9 legacy archive holds the letters'      ((Get-ChildItem (Join-Path $Root 'archive\alice') -Recurse -Filter ($legacyId + '.md')).Count -ge 1)

    # ---- T14 (review P0-1): legacy reply lands as sent\<id>.md; consecutive
    # sends are keyed by their own envelope id and never collide ----
    Write-Host 'T14 legacy reply: master keyed by envelope id, two sends never collide'
    $legReqId = 'msg-20260101-000000-alice-leg9'
    $legReq = '---' + "`r`n" + 'id: ' + $legReqId + "`r`n" + 'topic: t-20260101-leg9' + "`r`n" + 'subject: legacy era' + "`r`n" + 'from: alice' + "`r`n" + 'to: bob' + "`r`n" + 'type: request' + "`r`n" + 'created: 2026-01-01T00:00:00+08:00' + "`r`n" + 'state: open' + "`r`n" + '---' + "`r`n`r`n" + 'legacy request body' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\bob\inbox') ($legReqId + '.md')), $legReq, (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') ($legReqId + '.md')), $legReq, (New-Object System.Text.UTF8Encoding($true)))
    $r1 = New-TestLetter -Root $Root -From bob -To alice -Topic t-20260101-leg9 -Type reply -Subject 'legacy reply 1' -Body 'legacy reply one' -InReplyTo $legReqId
    $o14 = Invoke-Send -LetterPath $r1
    $r1id = [System.IO.Path]::GetFileNameWithoutExtension($r1)
    Assert 'T14 legacy reply lands as sent\<id>.md' ((Test-Path (Join-Path (Join-Path $Root 'mailboxes\bob\sent') ($r1id + '.md')))) $o14
    $r2 = New-TestLetter -Root $Root -From bob -To alice -Topic t-20260101-leg9 -Type reply -Subject 'legacy reply 2' -Body 'legacy reply two' -InReplyTo $legReqId
    $null = Invoke-Send -LetterPath $r2
    $r2id = [System.IO.Path]::GetFileNameWithoutExtension($r2)
    Assert 'T14 second reply lands as its own <id>.md' ((Test-Path (Join-Path (Join-Path $Root 'mailboxes\bob\sent') ($r2id + '.md'))))
    Assert 'T14 first master untouched (no collision)' ((Test-Path (Join-Path (Join-Path $Root 'mailboxes\bob\sent') ($r1id + '.md'))))
    $statusFile = Join-Path (Join-Path $Root 'mailboxes\alice\sent') ($legReqId + '.status')
    $stTxt = if (Test-Path $statusFile) { [System.IO.File]::ReadAllText($statusFile) } else { '' }
    Assert 'T14 requester master flips REPLIED (v2 semantics preserved)' ($stTxt -match 'REPLIED')

    # ---- T10: backfill criterion (P5) - delete a jsonl row, backfill restores it ----
    Write-Host 'T10 backfill: set-equality criterion after a lost row'
    $jsonl = Join-Path $Root 'archive\index.jsonl'
    $lines = [System.IO.File]::ReadAllLines($jsonl) | Where-Object { $_ -notmatch 't-20260101-leg0' }
    [System.IO.File]::WriteAllLines($jsonl, $lines, (New-Object System.Text.UTF8Encoding($false)))
    $ob = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'ops\backfill-archive-index.ps1') -Root $Root 2>&1 | Out-String
    Assert 'T10 backfill criterion MET (union == jsonl)' ($ob -match 'criterion MET')
    $jsonlAfter = [System.IO.File]::ReadAllText($jsonl)
    Assert 'T10 lost row restored by backfill'        ($jsonlAfter -match 't-20260101-leg0')

    # ---- T11: unofficial gate - a shadow letter with no trace is flagged ----
    Write-Host 'T11 unofficial: shadow letter flagged in mail-check'
    $shadowFm = '---' + "`r`n" + 'id: msg-20260101-000000-alice-sh9' + "`r`n" + 'topic: t-20260101-sh9' + "`r`n" +
        'subject: shadow' + "`r`n" + 'from: alice' + "`r`n" + 'to: bob' + "`r`n" + 'type: request' + "`r`n" +
        'created: 2026-01-01T00:00:00+08:00' + "`r`n" + 'state: open' + "`r`n" + '---' + "`r`n`r`n" + 'shadow body' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $Root 'mailboxes\bob\inbox\msg-20260101-000000-alice-sh9.md'), $shadowFm, (New-Object System.Text.UTF8Encoding($true)))
    $mc = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'mail-check.ps1') -Agent bob -Root $Root 2>&1 | Out-String
    Assert 'T11 shadow letter flagged unofficial'     ($mc -match 'unofficial')

    # ---- T12: redirect - initiator reroutes a pending topic, post office executes ----
    Write-Host 'T12 redirect: pending topic rerouted bob -> testbot'
    foreach ($d in @('mailboxes\testbot\inbox','mailboxes\testbot\outbox','mailboxes\testbot\processing','mailboxes\testbot\sent','mailboxes\testbot\notes')) {
        New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'registry') 'testbot.md'), ($card -f 'testbot'), (New-Object System.Text.UTF8Encoding($true)))
    $l12 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst3 -Type request -Subject 'redirect probe' -Body 'redirect probe body.'
    $null = Invoke-Send -LetterPath $l12
    $or = & powershell -NoProfile -ExecutionPolicy Bypass -File $send -Redirect -Topic t-20260101-tst3 -RedirectTo testbot -Root $Root 2>&1 | Out-String
    Assert 'T12 redirect executed'                    ($or -match 'REDIRECTED')
    $st = Get-Content (Join-Path $threads 't-20260101-tst3\status.json') -Raw | ConvertFrom-Json
    Assert 'T12 status.to flipped to testbot'         ([string]$st.to -eq 'testbot')
    Assert 'T12 state back to pending'                ([string]$st.state -eq 'pending')
    Assert 'T12 chain copy now in testbot inbox'      (Test-Path (Join-Path $Root 'mailboxes\testbot\inbox\t-20260101-tst3.chain.md'))
    Assert 'T12 bob copy cleared'                     (-not (Test-Path (Join-Path $Root 'mailboxes\bob\inbox\t-20260101-tst3.chain.md')))

    # ---- T13: integrity chain audit passes on the healthy tree ----
    Write-Host 'T13 integrity: chain audit green'
    $oi = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'core\integrity.ps1') -Root $Root 2>&1 | Out-String
    Assert 'T13 integrity exits clean (no chain drift)' ($LASTEXITCODE -eq 0 -and $oi -notmatch 'ORPHAN|not in chain list')
    Assert 'T13 integrity summary carries chain counters' ($oi -match 'chain_topics=\d+') $oi

    # ---- T15 (A7, plan A6): created normalization + post-office stamps ----
    Write-Host 'T15 clock: drifted created normalized, created_original + taken_at stamped'
    $oldStamp15 = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $l15 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst4 -Type request -Subject 'clock stamp probe' -Body 'clock stamp body.'
    $txt15 = [System.IO.File]::ReadAllText($l15) -replace '(?m)^created\s*:.*$', ('created: ' + $oldStamp15)
    [System.IO.File]::WriteAllText($l15, $txt15, (New-Object System.Text.UTF8Encoding($true)))
    $o15 = Invoke-Send -LetterPath $l15
    Assert 'T15 drifted letter delivered'            ($o15 -match 'DELIVERED') $o15
    $m15 = Join-Path (Join-Path $Root 'mailboxes\alice\sent') (Split-Path $l15 -Leaf)
    $fm15 = [System.IO.File]::ReadAllText($m15)
    $c15 = if ($fm15 -match '(?m)^created\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
    $co15 = if ($fm15 -match '(?m)^created_original\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
    $ta15 = if ($fm15 -match '(?m)^taken_at\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
    $c15ok = $false
    try { $c15ok = ([datetime]::Parse($c15) -gt (Get-Date).AddMinutes(-2)) } catch {}
    Assert 'T15 created normalized to post-office time' $c15ok ('created=' + $c15)
    Assert 'T15 created_original kept'               ($co15 -eq $oldStamp15) ('original=' + $co15)
    Assert 'T15 taken_at stamped'                    ($ta15 -ne '')

    # ---- T16 (A7, plan A6 + workbuddy patch): drift > 24h is RETURNED ----
    Write-Host 'T16 clock: 25h drift returned, not normalized'
    $l16 = New-TestLetter -Root $Root -From alice -To bob -Topic t-20260101-tst5 -Type request -Subject 'drift return probe' -Body 'drift return body.'
    $old25 = (Get-Date).AddHours(-25).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $txt16 = [System.IO.File]::ReadAllText($l16) -replace '(?m)^created\s*:.*$', ('created: ' + $old25)
    [System.IO.File]::WriteAllText($l16, $txt16, (New-Object System.Text.UTF8Encoding($true)))
    $o16 = Invoke-Send -LetterPath $l16
    Assert 'T16 25h drift RETURNED'                  ($o16 -match 'RETURNED') $o16
    $side16 = Join-Path (Join-Path $Root 'mailboxes\alice\sent') ([System.IO.Path]::ChangeExtension((Split-Path $l16 -Leaf), '.status'))
    Assert 'T16 return reason names the drift'       ((Test-Path -LiteralPath $side16) -and (([System.IO.File]::ReadAllText($side16)) -match 'drift'))

    # ---- T17 (A7, plan A4 + workbuddy patch): cleanup terminal gate ----
    # STATUS ok is terminal (never requeued), STATUS failed keeps the requeue
    # path, PULL recipients (wake: TODO) are never requeued. The failed case
    # needs a PUSH card - alice/bob are PULL, so carol carries it.
    Write-Host 'T17 cleanup: STATUS ok terminal, failed requeues, PULL skipped'
    foreach ($d in @('mailboxes\carol\inbox','mailboxes\carol\outbox','mailboxes\carol\processing','mailboxes\carol\sent','mailboxes\carol\notes')) {
        New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
    }
    $card17 = '---' + "`r`n" + 'name: carol' + "`r`n" + 'inbox: mailboxes\carol\inbox' + "`r`n" + 'model: test-model' + "`r`n" + 'wake: exec cmd /c echo ok' + "`r`n" + '---' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'registry') 'carol.md'), $card17, (New-Object System.Text.UTF8Encoding($true)))
    function New-ProcLetter17 {
        param([string]$Agent, [string]$Id, [string]$Topic)
        $fm17 = '---' + "`r`n" + 'id: ' + $Id + "`r`n" + 'topic: ' + $Topic + "`r`n" + 'subject: cleanup probe' + "`r`n" +
            'from: alice' + "`r`n" + 'to: ' + $Agent + "`r`n" + 'type: request' + "`r`n" +
            'created: 2026-01-01T00:00:00+08:00' + "`r`n" + 'state: open' + "`r`n" + '---' + "`r`n`r`n" + 'cleanup probe body' + "`r`n"
        $p = Join-Path (Join-Path (Join-Path $Root 'mailboxes') ($Agent + '\processing')) ($Id + '.md')
        [System.IO.File]::WriteAllText($p, $fm17, (New-Object System.Text.UTF8Encoding($true)))
        return $p
    }
    $pOk17   = New-ProcLetter17 -Agent 'alice' -Id 'msg-20260101-000000-alice-cl1' -Topic 't-20260101-cl1'
    $pFail17 = New-ProcLetter17 -Agent 'carol' -Id 'msg-20260101-000000-alice-cl2' -Topic 't-20260101-cl2'
    $pPull17 = New-ProcLetter17 -Agent 'alice' -Id 'msg-20260101-000000-alice-cl3' -Topic 't-20260101-cl3'
    $dispLine = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] DISPATCHED (post office notifying via registered channels)'
    # sidecar naming: cleanup resolves <stem>.progress via ChangeExtension - the
    # '.md' is stripped (a '<id>.md.progress' name would be invisible to it)
    $sOk17   = [System.IO.Path]::ChangeExtension($pOk17, '.progress')
    $sFail17 = [System.IO.Path]::ChangeExtension($pFail17, '.progress')
    $sPull17 = [System.IO.Path]::ChangeExtension($pPull17, '.progress')
    [System.IO.File]::WriteAllText($sOk17,   ($dispLine + "`r`n" + 'STATUS ok via exec' + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText($sFail17, ($dispLine + "`r`n" + 'STATUS failed code=2 reason=probe' + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText($sPull17, ($dispLine + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    foreach ($p in @($pOk17, $pFail17, $pPull17)) {
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddHours(-2)
    }
    foreach ($s in @($sOk17, $sFail17, $sPull17)) {
        if (Test-Path -LiteralPath $s) { (Get-Item -LiteralPath $s).LastWriteTime = (Get-Date).AddHours(-2) }
    }
    $oc17 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'core\cleanup.ps1') -Root $Root 2>&1 | Out-String
    Assert 'T17 STATUS ok letter NOT requeued'       (Test-Path -LiteralPath $pOk17) $oc17
    Assert 'T17 STATUS failed letter requeued'       ((Test-Path (Join-Path (Join-Path $Root 'mailboxes\carol\inbox') 'msg-20260101-000000-alice-cl2.md')) -and -not (Test-Path -LiteralPath $pFail17)) $oc17
    Assert 'T17 PULL letter NOT requeued'            (Test-Path -LiteralPath $pPull17) $oc17
    $sys17 = if (Test-Path (Join-Path (Join-Path $Root 'logs') 'system.log')) { [System.IO.File]::ReadAllText((Join-Path (Join-Path $Root 'logs') 'system.log')) } else { '' }
    Assert 'T17 TERMINAL skip logged'                ($sys17 -match 'TERMINAL skip requeue')

    # ---- T18 (A7, plan A5 + workbuddy放行条件): journal REPLIED reconciliation ----
    Write-Host 'T18 route: REPLIED journal reconciliation at the exhaustion bound'
    # recipient must be PUSH: the PULL-mode exit fires before the dispatch
    # guards, so a wake:TODO recipient never reaches the exhaustion branch
    function New-InboxLetter18 {
        param([string]$Id, [string]$Topic)
        $fm18 = '---' + "`r`n" + 'id: ' + $Id + "`r`n" + 'topic: ' + $Topic + "`r`n" + 'subject: route recon probe' + "`r`n" +
            'from: alice' + "`r`n" + 'to: carol' + "`r`n" + 'type: request' + "`r`n" +
            'created: 2026-01-01T00:00:00+08:00' + "`r`n" + 'state: open' + "`r`n" + '---' + "`r`n`r`n" + 'route recon probe body' + "`r`n"
        $p = Join-Path (Join-Path $Root 'mailboxes\carol\inbox') ($Id + '.md')
        [System.IO.File]::WriteAllText($p, $fm18, (New-Object System.Text.UTF8Encoding($true)))
        return $p
    }
    # positive: 3 DISPATCHED lines + a REPLIED journal line -> no bounce
    $p18 = New-InboxLetter18 -Id 'msg-20260101-000000-alice-rt1' -Topic 't-20260101-rt1'
    $disp18 = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] DISPATCHED (post office notifying via registered channels)'
    # route reads the sidecar via ChangeExtension (no '.md'): name it accordingly
    $s18 = [System.IO.Path]::ChangeExtension($p18, '.progress')
    [System.IO.File]::WriteAllText($s18, ($disp18 + "`r`n" + $disp18 + "`r`n" + $disp18 + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt1.md'), ([System.IO.File]::ReadAllText($p18)), (New-Object System.Text.UTF8Encoding($true)))
    $jl18 = Join-Path (Join-Path $Root 'logs') 'alice\journal.log'
    New-Item -ItemType Directory -Path (Split-Path $jl18 -Parent) -Force | Out-Null
    [System.IO.File]::AppendAllText($jl18, ('2026-01-01 00:00:00 | REPLIED   | msg-20260101-000000-alice-rt1 <- msg-20260101-000000-bob-aa1' + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $o18 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'core\route.ps1') -File $p18 -Root $Root 2>&1 | Out-String
    Assert 'T18 answered letter NOT returned'        ($o18 -notmatch 'RETURNED') $o18
    Assert 'T18 REPLIED-ACK issued'                  ($o18 -match 'REPLIED-ACK') $o18
    Assert 'T18 master flipped REPLIED'              (((Test-Path (Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt1.status')) -and ([System.IO.File]::ReadAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt1.status')) -match 'REPLIED')))
    Assert 'T18 stale copy quarantined to trash'     (-not (Test-Path -LiteralPath $p18))
    # negative: same exhaustion, no journal line -> returned as before
    $p18b = New-InboxLetter18 -Id 'msg-20260101-000000-alice-rt2' -Topic 't-20260101-rt2'
    [System.IO.File]::WriteAllText(([System.IO.Path]::ChangeExtension($p18b, '.progress')), ($disp18 + "`r`n" + $disp18 + "`r`n" + $disp18 + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt2.md'), ([System.IO.File]::ReadAllText($p18b)), (New-Object System.Text.UTF8Encoding($true)))
    $o18b = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'core\route.ps1') -File $p18b -Root $Root 2>&1 | Out-String
    Assert 'T18 unanswered letter still RETURNED'    ($o18b -match 'RETURNED') $o18b
    Assert 'T18 unanswered master stamped RETURNED'  ((Test-Path (Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt2.status')) -and ([System.IO.File]::ReadAllText((Join-Path (Join-Path $Root 'mailboxes\alice\sent') 'msg-20260101-000000-alice-rt2.status')) -match 'RETURNED'))

    Write-Host ''
    Write-Host ('v3 selftest result: pass=' + $pass + ' fail=' + $fail + '  root: ' + $Root)
    if ($fail -gt 0) { Write-Host ('sandbox KEPT for post-mortem: ' + $Root); exit 1 }
} finally {
    if (-not $rootProvided -and -not $Keep -and $script:fail -eq 0) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($script:fail -gt 0) { exit 1 }
exit 0
