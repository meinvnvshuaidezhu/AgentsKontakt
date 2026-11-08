param(
  [string]$File = '',
  [string]$Root = '',
  # v3 redirect (§2.2): initiator-triggered, post-office-executed topic
  # reassignment. Usage: send.ps1 -Redirect -Topic <t-...> -RedirectTo <agent>
  [switch]$Redirect,
  [string]$Topic = '',
  [string]$RedirectTo = '',
  [switch]$Selftest
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# --selftest (r4.1 §7-3): run the throwaway-root full-chain regression.
if ($Selftest) {
    & (Join-Path (Join-Path $PSScriptRoot 'tests') 'test-v3-selftest.ps1')
    exit $LASTEXITCODE
}


# ---- v3 redirect (initiator-triggered, post office executes) ----------------
if ($Redirect) {
    if (-not $Topic -or -not $RedirectTo) {
        Write-Error (Get-AkText 'send.redirect-usage' 'redirect usage: send.ps1 -Redirect -Topic <t-...> -RedirectTo <new-recipient>'); exit 1
    }
    $stR = Get-TopicStatus -Topic $Topic
    if (-not $stR) { Write-Error (Get-AkText 'send.redirect-no-topic' 'redirect: no v3 topic: {0}' $Topic); exit 1 }
    # the initiator is whoever the topic says - send.ps1 has no session identity
    try {
        $r = Invoke-TopicRedirect -Topic $Topic -Initiator ([string]$stR.from) -NewTo $RedirectTo
        Write-Host (Get-AkText 'send.redirect-ok' 'REDIRECTED {0}: {1} -> {2}' $Topic $r.oldTo $r.newTo)
    } catch {
        Write-Error (Get-AkText 'send.redirect-failed' 'redirect failed: {0}' $_.Exception.Message); exit 1
    }
    exit 0
}

if (-not $File) { Write-Error (Get-AkText 'send.usage' 'usage: send.ps1 -File <outbox mail path> | -Redirect -Topic <t> -RedirectTo <agent>'); exit 1 }

# v2 post-office take-out module. Invoked by watch.ps1 on the take bell
# (outbox rename event / quiet-window sweep), or directly by an agent during
# the transition period - both go through this single pipeline:
#   envelope gates -> channel chain -> copy delivery -> receipt/bounce.
#
# Delivery is COPY-with-master: the copy goes into the recipient's inbox,
# the master moves into the sender's sent area with a status sidecar
# (status/reason/updated) so an unfinished letter is always trackable.
# Any gate failure RETURNS the mail to the outbox owner: master parked in
# their sent area with status RETURNED + reason, plus a bounce system mail
# (routed immediately - the sender must act on it).

if (-not (Test-Path -LiteralPath $File)) { Write-Host (Get-AkText 'send.already-taken' 'already taken or gone'); exit 0 }
$File = (Get-Item -LiteralPath $File).FullName
$owner = Get-OutboxOwner -FilePath $File
if (-not $owner) { Write-Error (Get-AkText 'send.err-not-outbox' 'file is not inside a registered outbox: {0}' $File); exit 1 }

function Get-SentDir {
    param([string]$AgentName)
    return (Join-Path (Join-Path $script:DirMailboxes $AgentName) 'sent')
}

function Move-MasterToSent {
    # §2.5-1 anti-overwrite, keyed on the ENVELOPE ID (not the file name - a
    # rewritten-id letter must not bypass the check; 2026-11-06 incident). The
    # master is normalized to <id>.md on landing. An existing master is THE
    # record: refuse, keep it untouched, quarantine the newcomer in post\cold
    # (no .1/.2 renames - sent semantics are one master per id). Returns the
    # master path, or $null when refused. Alarm goes to the agent (owner sees
    # it via system.log + dashboard feed).
    param([string]$Path, [string]$AgentName, [string]$MsgId)
    $sentDir = Get-SentDir -AgentName $AgentName
    $dest = Join-Path $sentDir ($MsgId + '.md')
    if (Test-Path -LiteralPath $dest) {
        $stamp = Get-Date -Format 'HHmmss'
        $quarantine = Join-Path $script:DirCold ($MsgId + '-dup-' + $stamp + [System.IO.Path]::GetExtension($Path))
        Move-AtomicTo -File $Path -DestPath $quarantine | Out-Null
        # n5w8 §5 step 4: a quarantine without a reason note is a future
        # mystery - record who/when/why beside the file (orphan-scan picks it
        # up as a cold-quarantine finding and the note travels with it).
        Write-TextFile -Path ($quarantine + '.why.md') -Content ('quarantined: ' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') + "`r`nby: post office (Move-MasterToSent anti-overwrite, §2.5-1)`r`nwhy: a second mail with envelope id " + $MsgId + " arrived while the master was already in sent")
        Write-Journal -Agent $AgentName -Action 'WARN' -Detail ('sent-overwrite blocked: master kept (' + $MsgId + '.md); newcomer quarantined: ' + [System.IO.Path]::GetFileName($quarantine))
        $bytes = 0
        try { $bytes = (Get-Item -LiteralPath $quarantine).Length } catch {}
        $body = (Get-AkLines 'send.overwrite.body' 'A second mail with an existing id arrived and was BLOCKED from overwriting your sent master.' '' 'existing master: {0}' 'newcomer quarantined: {1} ({2} bytes)' '' 'If this was a resend, use a NEW message id. The owner sees this alarm in the dashboard feed.' |
            ForEach-Object { $_ -f ([System.IO.Path]::GetFileName($dest)), ([System.IO.Path]::GetFileName($quarantine)), $bytes }) -join "`r`n"
        $alarm = Write-SystemMail -To $AgentName -Topic ([string](Read-FrontMatter -Path $quarantine)['topic']) -Subject ('OVERWRITE-BLOCKED ' + $MsgId) -Body $body
        Write-SystemLog ('send: overwrite blocked for ' + $AgentName + ' - ' + $MsgId)
        Write-Host (Get-AkText 'send.overwrite-blocked' 'OVERWRITE-BLOCKED {0} (master kept; newcomer in cold)' $MsgId)
        return $null
    }
    return (Move-AtomicTo -File $Path -DestPath $dest)
}

function Return-Mail {
    # Park the master in the owner's sent area, stamp RETURNED + reason,
    # drop a bounce system mail and route it (the sender must act). Never throws.
    # §2.5-3: bounce carries the master byte count (truncation visible at a glance).
    param([string]$Path, [string]$Reason, [string]$Topic, [string]$ToAgent, [string]$MsgId)
    try {
        $masterSize = 0
        try { $masterSize = (Get-Item -LiteralPath $Path).Length } catch {}
        $master = Move-MasterToSent -Path $Path -AgentName $ToAgent -MsgId $MsgId
        if (-not $master) {
            # anti-overwrite refused (an earlier master exists): the newcomer is
            # already quarantined - treat the RETURN as informational only.
            Write-Journal -Agent $ToAgent -Action 'RETURN' -Detail ($MsgId + ' | ' + $Reason + ' | master kept, newcomer quarantined')
            return
        }
        Set-MailStatus -MessagePath $master -Status 'RETURNED' -Reason $Reason -Topic $Topic | Out-Null
        Write-Journal -Agent $ToAgent -Action 'RETURN' -Detail ($MsgId + ' | ' + $Reason + ' | master_bytes=' + $masterSize)
        $body = (Get-AkLines 'send.bounce.body' 'Your outbox mail was returned by the post office.' '' 'id: {0}' 'reason: {1}' 'master_bytes: {2}' '' 'The master copy is in your sent area (status RETURNED). Fix the problem and hand it in again.' |
            ForEach-Object { $_ -f $MsgId, $Reason, $masterSize }) -join "`r`n"
        $bounce = Write-SystemMail -To $ToAgent -Topic $Topic -Subject ('RETURNED ' + $MsgId) -Body $body
        $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'core\route.ps1') -File $bounce -Root $script:Root 2>&1
    } catch {
        Write-SystemLog ('return failed for ' + $MsgId + ' :: ' + $_.Exception.Message)
    }
}

$fm = Read-FrontMatter -Path $File
$fallbackId = [System.IO.Path]::GetFileNameWithoutExtension($File)

# Gate 0 (v2.3.8): encoding gate. Every letter must be valid UTF-8; on pass
# the file is normalized to UTF-8 with BOM so every later reader - including
# bare PS 5.1 Get-Content with no encoding argument - decodes it correctly.
$rawBytes = [System.IO.File]::ReadAllBytes($File)
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)   # throwOnInvalidBytes
try { $null = $strictUtf8.GetString($rawBytes) } catch {
    $badId = if ($fm.ContainsKey('id')) { [string]$fm['id'] } else { $fallbackId }
    $badTopic = if ($fm.ContainsKey('topic')) { [string]$fm['topic'] } else { '' }
    Return-Mail -Path $File -Reason 'bad envelope: not valid UTF-8' -Topic $badTopic -ToAgent $owner -MsgId $badId
    exit 0
}
if (-not ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)) {
    Write-TextFile -Path $File -Content ([System.IO.File]::ReadAllText($File))   # re-emit with BOM
}

# Gate 0b (v3 §2.5-4): deterministic envelope validation. Read-FrontMatter
# already tolerates a BOM (regex \A--- would fail on a raw BOM; ReadAllText
# via .NET keeps the BOM out of the match because it is stripped by the
# decoder) - here we add the checks a torn or malformed file can still pass:
# strict id format (the idempotency key everywhere), a parseable created
# timestamp (every stall/timeout window sorts on it), and a non-empty body.
$id0 = [string]$fm['id']
if ($id0 -and $id0 -notmatch '^msg-\d{8}-\d{6}-[a-z0-9]+-[a-z0-9]{4}$') {
    Return-Mail -Path $File -Reason 'bad envelope: id not in msg-yyyyMMdd-HHmmss-from-rrrr format' -Topic ([string]$fm['topic']) -ToAgent $owner -MsgId $id0
    Write-Host (Get-AkText 'send.returned.id-format' 'RETURNED {0} (id format)' $id0)
    exit 0
}
$createdRaw = [string]$fm['created']
if ($createdRaw) {
    try { $null = [datetime]::Parse($createdRaw) } catch {
        Return-Mail -Path $File -Reason 'bad envelope: created not parseable as a timestamp' -Topic ([string]$fm['topic']) -ToAgent $owner -MsgId $id0
        Write-Host (Get-AkText 'send.returned.created-format' 'RETURNED {0} (created format)' $id0)
        exit 0
    }
}
$bodyProbe = Get-LetterBody -Path $File
if (-not $bodyProbe) {
    Return-Mail -Path $File -Reason 'bad envelope: empty body' -Topic ([string]$fm['topic']) -ToAgent $owner -MsgId $id0
    Write-Host (Get-AkText 'send.returned.empty-body' 'RETURNED {0} (empty body)' $id0)
    exit 0
}

foreach ($k in @('id','topic','from','to','type','created')) {
    if (-not ($fm.ContainsKey($k)) -or [string]::IsNullOrWhiteSpace([string]$fm[$k])) {
        Return-Mail -Path $File -Reason ('bad envelope: missing ' + $k) -Topic ([string]$fm['topic']) -ToAgent $owner -MsgId $fallbackId
        Write-Host (Get-AkText 'send.returned.bad-envelope' 'RETURNED (bad envelope: missing {0})' $k)
        exit 0
    }
}
$id = [string]$fm['id']; $from = [string]$fm['from']; $to = [string]$fm['to']
$type = [string]$fm['type']; $topic = [string]$fm['topic']

function Add-EnvelopeField {
    # A6 helper: insert (or replace) one front-matter field line before the
    # closing '---'. Line-scoped - never touches the body. Rewrites the file
    # UTF-8 with BOM.
    param([string]$Path, [string]$Key, [string]$Value)
    $lines = [System.IO.File]::ReadAllLines($Path)
    $close = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '---') { $close = $i; break } }
    if ($close -lt 1) { return $false }
    $head = New-Object System.Collections.Generic.List[string]
    $keyRe = '^' + [regex]::Escape($Key) + '\s*:'
    for ($i = 0; $i -lt $close; $i++) { if ($lines[$i] -notmatch $keyRe) { $head.Add($lines[$i]) } }
    $head.Add($Key + ': ' + $Value)
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange($head)
    for ($i = $close; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
    [System.IO.File]::WriteAllText($Path, (($out -join "`r`n") + "`r`n"), $script:UTF8Bom)
    return $true
}

# ---- A6 (t-20261107-ix07, owner-approved; workbuddy patches applied) --------
# Clock duties. Agents hand-write created values that drift (10/10 letters of
# one night were created AFTER they landed on disk; hermes once stamped a
# future round-minute - template filling). Discipline clauses cannot fix what
# the pipeline can stamp: the post office is the clock of record.
#   drift > 24h   -> RETURN (a fabricated timestamp is an envelope defect;
#                    an always-shifted system clock would otherwise all-block)
#   drift > 60min -> WARN + normalize
#   drift > 2min  -> normalize silently
# AK_SKIP_CLOCK_CHECK=1 disables the whole gate (operator escape hatch).
# The original value survives as created_original; the receipt carries the
# note. taken_at (pipeline takeover) is stamped below; delivered_at lands on
# the recipient copy in the legacy flow (v3 records it per-copy in
# status.json copies). B-phase note: neither stamp may ever enter a chain
# hash - they differ per pipeline stage by design.
$script:CreatedDriftNote = ''
if ($createdRaw -and -not $env:AK_SKIP_CLOCK_CHECK) {
    try {
        $createdDt = [datetime]::Parse($createdRaw)
        $nowPo = Get-Date
        $driftMin = [Math]::Abs(($nowPo - $createdDt).TotalMinutes)
        if ($driftMin -gt 1440) {
            Return-Mail -Path $File -Reason ('bad envelope: created drifts ' + [int]$driftMin + 'min from post-office time (created=' + $createdRaw + ', now=' + $nowPo.ToString('yyyy-MM-ddTHH:mm:sszzz') + '); set AK_SKIP_CLOCK_CHECK=1 to disable this gate') -Topic $topic -ToAgent $owner -MsgId $id
            Write-Host (Get-AkText 'send.returned.created-drift' 'RETURNED {0} (created drift > 24h)' $id)
            exit 0
        }
        if ($driftMin -gt 2) {
            $normStamp = $nowPo.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
            $null = Add-EnvelopeField -Path $File -Key 'created' -Value $normStamp
            $null = Add-EnvelopeField -Path $File -Key 'created_original' -Value $createdRaw
            $fm = Read-FrontMatter -Path $File
            $script:CreatedDriftNote = ('post-office clock stamp: envelope created drifted ' + [int]$driftMin + ' min and was normalized (original: ' + $createdRaw + ')')
            if ($driftMin -gt 60) {
                Write-SystemLog ('WARN created drift ' + [int]$driftMin + 'min normalized: ' + $owner + '\' + $id + ' (original ' + $createdRaw + ')')
                Write-Journal -Agent $owner -Action 'WARN' -Detail ($id + ' | created drift ' + [int]$driftMin + 'min normalized (original ' + $createdRaw + ')')
            }
        }
    } catch {}
}
# taken_at: the moment the pipeline took the letter over (post-office clock).
$null = Add-EnvelopeField -Path $File -Key 'taken_at' -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'))
$fm = Read-FrontMatter -Path $File

if ($type -notin @('request','reply','broadcast')) {
    Return-Mail -Path $File -Reason ('bad envelope: invalid type ' + $type) -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.invalid-type' 'RETURNED {0} (invalid type)' $id)
    exit 0
}
if ($type -eq 'request' -and [string]::IsNullOrWhiteSpace([string]$fm['subject'])) {
    Return-Mail -Path $File -Reason 'bad envelope: request without subject' -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.request-no-subject' 'RETURNED {0} (request without subject)' $id)
    exit 0
}
$subj = [string]$fm['subject']
if ($subj -and $subj.Length -gt 60) {
    Return-Mail -Path $File -Reason 'bad envelope: subject too long (max 60)' -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.subject-too-long' 'RETURNED {0} (subject too long)' $id)
    exit 0
}
if ($to -eq $from) {
    Return-Mail -Path $File -Reason 'bad envelope: to equals from' -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.to-equals-from' 'RETURNED {0} (to equals from)' $id)
    exit 0
}
if ($id -notmatch '^[A-Za-z0-9_\-\.]+$') {
    Return-Mail -Path $File -Reason 'bad envelope: id not ascii' -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.id-not-ascii' 'RETURNED {0} (id not ascii)' $id)
    exit 0
}

# Gate 1: anti-spoofing - the envelope sender must be the outbox owner.
if ($from -ne $owner) {
    Return-Mail -Path $File -Reason ('spoofed from: envelope from=' + $from + ', outbox owner=' + $owner) -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.spoofed' 'RETURNED {0} (spoofed from)' $id)
    exit 0
}

# Gate 1b: the recipient must be registered and have a living inbox.
$agents = Get-RegisteredAgents
$target = $agents | Where-Object { $_.name -eq $to }
if (-not $target) {
    Return-Mail -Path $File -Reason ('recipient not registered: ' + $to) -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.recipient-not-registered' 'RETURNED {0} (recipient not registered)' $id)
    exit 0
}
$targetInbox = Join-Path $Root ([string]$target.inbox)
if (-not (Test-Path -LiteralPath $targetInbox)) {
    Return-Mail -Path $File -Reason 'target inbox missing (run init.ps1)' -Topic $topic -ToAgent $owner -MsgId $id
    Write-Host (Get-AkText 'send.returned.target-inbox-missing' 'RETURNED {0} (target inbox missing)' $id)
    exit 0
}
$targetProc = Join-Path (Split-Path $targetInbox -Parent) 'processing'
foreach ($d in @($targetInbox, $targetProc)) {
    if (Test-Path -LiteralPath (Join-Path $d ($id + '.md'))) {
        Return-Mail -Path $File -Reason 'duplicate message id in target mailbox' -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.duplicate-id' 'RETURNED {0} (duplicate id)' $id)
        exit 0
    }
}

# Gate 1c (v2): a related topic must really exist in the archive.
$rel = [string]$fm['related_topic']
if ($rel) {
    if ($rel -notmatch '^t-[A-Za-z0-9\-]+$') {
        Return-Mail -Path $File -Reason 'bad envelope: related_topic malformed' -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.related-malformed' 'RETURNED {0} (related_topic malformed)' $id)
        exit 0
    }
    $hit = Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Directory -Filter $rel -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) {
        # vqwc gap 1 (t-20261107-vqwc): the reason used to read like "you typed
        # a wrong topic id", sending agents off to fix the NUMBER and lose a
        # second letter - the actual rule is: in-flight topics take an empty
        # related_topic. Say so.
        Return-Mail -Path $File -Reason ('related topic not found in archive: ' + $rel + ' (related_topic only points at ARCHIVED topics - leave it empty while the related topic is still open)') -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.related-not-found' 'RETURNED {0} (related topic not found)' $id)
        exit 0
    }
}

# Gates passed. ---- v3 state-machine integration (r4.1 §2.2/§3) ----
$kind = [string]$fm['kind']
if (-not $kind -or $kind -notin @('question', 'answer', 'archive-note')) {
    $kind = switch ($type) { 'reply' { 'answer' } default { 'question' } }
}
$isV3 = Test-Path -LiteralPath (Get-StatusPath -Topic $topic)

if ($isV3) {
    # existing v3 topic: the letter is a turn on the neutral chain
    $st = Get-TopicStatus -Topic $topic
    if (-not $st) {
        Return-Mail -Path $File -Reason 'v3 status.json unreadable' -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.v3' 'RETURNED {0} (v3 status unreadable)' $id); exit 0
    }
    # sender identity per kind (§2.2): answer = current recipient; question /
    # archive-note = initiator. Envelope from is already anti-spoofed (Gate 1).
    $allowed = switch ($kind) { 'answer' { [string]$st.to } 'question' { [string]$st.from } 'archive-note' { [string]$st.from } }
    if ($from -ne $allowed) {
        # vqwc gap 2 (t-20261107-vqwc): on an answered topic the initiator's
        # follow-up IS a question - without an explicit kind it defaults to
        # answer and trips this gate. Tell them the fix, not just the rule.
        $roleHint = ''
        if ([string]$st.state -eq 'answered' -and $from -eq [string]$st.from -and $kind -ne 'question') {
            $roleHint = ' (the topic is answered: an initiator follow-up must carry kind: question)'
        }
        Return-Mail -Path $File -Reason ('v3 role mismatch: kind=' + $kind + ' expects ' + $allowed + ', got ' + $from + $roleHint) -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.v3-role' 'RETURNED {0} (v3 role mismatch)' $id); exit 0
    }
    $bodyText = Get-LetterBody -Path $File
    try {
        $st = Add-ThreadEntry -Topic $topic -Agent $from -Kind $kind -MsgId $id -Body $bodyText
    } catch {
        Return-Mail -Path $File -Reason $_.Exception.Message -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.v3' 'RETURNED {0} ({1})' $id $_.Exception.Message); exit 0
    }
    $master = Move-MasterToSent -Path $File -AgentName $owner -MsgId $id
    if (-not $master) { exit 0 }   # anti-overwrite refused; alarm already out
    Set-MailStatus -MessagePath $master -Status 'DELIVERED' -Topic $topic -Peer $to | Out-Null
    # copies trace (§2.6 persistent evidence, survives copy clearing)
    $copies = @{}
    if ($st.copies) { foreach ($p in ($st.copies.PSObject.Properties)) { $copies[$p.Name] = $p.Value } }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $peer = switch ($kind) { 'answer' { [string]$st.from } default { [string]$st.to } }
    $peerInbox = Join-Path (Join-Path $script:DirMailboxes $peer) 'inbox'
    $copy = $null
    if ($kind -ne 'archive-note') {
        $copy = Copy-ThreadChainTo -Topic $topic -InboxDir $peerInbox
        $e = @{}; if ($copies[$peer]) { foreach ($q in ($copies[$peer].PSObject.Properties)) { $e[$q.Name] = $q.Value } }
        $e['delivered_at'] = $stamp; $e['bytes'] = [string]$st.chain_bytes; $e['cleared_at'] = ''
        $copies[$peer] = $e
    }
    if ($kind -eq 'answer') {
        # the answering side leaves zero traces (inbox + processing copies)
        $null = Clear-ThreadCopies -Topic $topic -Agent $from
        $e = @{}; if ($copies[$from]) { foreach ($q in ($copies[$from].PSObject.Properties)) { $e[$q.Name] = $q.Value } }
        $e['cleared_at'] = $stamp; $copies[$from] = $e
    }
    $null = Set-TopicStatus -Topic $topic -Fields @{ copies = $copies }
    Set-MailStatus -MessagePath $master -Status 'DELIVERED' -Topic $topic -Peer $peer | Out-Null
    Write-Journal -Agent $owner -Action 'SEND' -Detail ($id + ' | v3 ' + $kind + ' | topic=' + $topic + ' | state=' + [string]$st.state)
    # A5 support (t-20261107-pdup): v3 replies must ALSO flip the requester's
    # in-flight master and stamp the REPLIED journal line. The legacy flow does
    # this at the bottom of the script; the v3 branch used to exit before it,
    # so answered v3 letters had no reconciliation trace and route.ps1's
    # exhaustion reconciliation (A5) could not see them.
    if ($type -eq 'reply') {
        $origV3 = [string]$fm['in_reply_to']
        if ($origV3) {
            $reqMasterV3 = Join-Path (Get-SentDir -AgentName $to) ($origV3 + '.md')
            if (Test-Path -LiteralPath $reqMasterV3) {
                Set-MailStatus -MessagePath $reqMasterV3 -Status 'REPLIED' | Out-Null
                Write-Journal -Agent $to -Action 'REPLIED' -Detail ($origV3 + ' <- ' + $id)
            }
        }
    }
    if ($kind -eq 'archive-note') {
        # archived is terminal: move chain + status into the archive, clear both
        # mailboxes, notify both sides (the initiator gets this receipt too).
        $destDir = Invoke-TopicArchive -Topic $topic -ClosedBy $from
        $null = Clear-ThreadCopies -Topic $topic -Agent ([string]$st.to)
        $null = Clear-ThreadCopies -Topic $topic -Agent ([string]$st.from)
        $body = (Get-AkLines 'send.archived.body' 'Topic {0} has been archived by {1}.' '' 'archive: {2}' '' 'The neutral chain and its status are locked read-only in the archive; both mailboxes are cleared.' |
            ForEach-Object { $_ -f $topic, $from, $destDir }) -join "`r`n"
        $null = Write-SystemMail -To ([string]$st.to) -Topic $topic -Subject ('ARCHIVED ' + $topic) -Body $body
        $null = Write-SystemMail -To ([string]$st.from) -Topic $topic -Subject ('ARCHIVED ' + $topic) -Body $body
        Write-Host (Get-AkText 'send.archived' 'ARCHIVED {0} -> {1}' $topic $destDir)
        exit 0
    }
    # ring the peer: the chain copy sits in their inbox; route.ps1 doorbells it
    # in place (no physical claim for .chain.md views).
    $routeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'core\route.ps1') -File $copy -Root $Root 2>&1 | Out-String
    if ($routeOut.Trim()) { Write-Host $routeOut.Trim() }
    $receiptBody = (Get-AkLines 'send.receipt.body' 'Delivered to {0}.' '' 'id: {1}' 'Track it: read the .status sidecar next to the master in your sent area, or run scripts\mail-status.ps1 -Id {1}' |
        ForEach-Object { $_ -f $peer, $id }) -join "`r`n"
    if ($script:CreatedDriftNote) { $receiptBody += "`r`n`r`n" + $script:CreatedDriftNote }   # A6
    $receipt = Write-SystemMail -To $owner -Topic $topic -Subject ('DELIVERED ' + $id) -Body $receiptBody
    Write-Journal -Agent $owner -Action 'RECEIPT' -Detail ([System.IO.Path]::GetFileName($receipt))
    Write-Host (Get-AkText 'send.delivered' 'DELIVERED {0} -> {1}' $id $peer)
    exit 0
}

if ($kind -eq 'question' -and $type -eq 'request') {
    # new v3 topic: the letter body becomes turn 1 of thread-1.md
    $bodyText = Get-LetterBody -Path $File
    try {
        $st = New-ThreadTopic -Topic $topic -From $from -To $to -Subject $subj -Body $bodyText -Kind 'question' -MsgId $id
    } catch {
        Return-Mail -Path $File -Reason $_.Exception.Message -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.v3' 'RETURNED {0} ({1})' $id $_.Exception.Message); exit 0
    }
    $master = Move-MasterToSent -Path $File -AgentName $owner -MsgId $id
    if (-not $master) { exit 0 }
    Set-MailStatus -MessagePath $master -Status 'DELIVERED' -Topic $topic -Peer $to | Out-Null
    Add-ManifestEntry -Topic $topic -Path $master
    $copy = Copy-ThreadChainTo -Topic $topic -InboxDir $targetInbox
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $null = Set-TopicStatus -Topic $topic -Fields @{
        delivered_at = $stamp
        copies = @{ ($to) = @{ delivered_at = $stamp; bytes = [string]$st.chain_bytes; cleared_at = '' } }
    }
    Write-Journal -Agent $owner -Action 'SEND' -Detail ($id + ' | v3 new topic | topic=' + $topic)
    $routeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'core\route.ps1') -File $copy -Root $Root 2>&1 | Out-String
    if ($routeOut.Trim()) { Write-Host $routeOut.Trim() }
    $receiptBody = (Get-AkLines 'send.receipt.body' 'Delivered to {0}.' '' 'id: {1}' 'Track it: read the .status sidecar next to the master in your sent area, or run scripts\mail-status.ps1 -Id {1}' |
        ForEach-Object { $_ -f $to, $id }) -join "`r`n"
    $receipt = Write-SystemMail -To $owner -Topic $topic -Subject ('DELIVERED ' + $id) -Body $receiptBody
    Write-Journal -Agent $owner -Action 'RECEIPT' -Detail ([System.IO.Path]::GetFileName($receipt))
    Write-Host (Get-AkText 'send.delivered' 'DELIVERED {0} -> {1}' $id $to)
    exit 0
}

# legacy v2 flow (replies/requests without a v3 topic; broadcasts)
$sentDir = Get-SentDir -AgentName $owner
$master = Move-MasterToSent -Path $File -AgentName $owner -MsgId $id
if (-not $master) { exit 0 }
Set-MailStatus -MessagePath $master -Status 'DISPATCHING' -Topic $topic -Peer $to | Out-Null
Write-Journal -Agent $owner -Action 'TAKE' -Detail ($id + ' | ' + $from + '->' + $to + ' | topic=' + $topic + ' | ' + $type)

$copy = Copy-MailAtomic -File $master -DestDir $targetInbox
# A6: delivered_at stamped by the post office onto the recipient copy (legacy
# flow; v3 records it per-copy in status.json instead).
$null = Add-EnvelopeField -Path $copy -Key 'delivered_at' -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'))

# Channel chain (claim-as-mutex inside; PULL targets keep the copy in their
# inbox - that counts as delivered). Child process on purpose: route.ps1
# exits non-zero on total failure and `exit` must not unwind this pipeline.
$routeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'core\route.ps1') -File $copy -Root $Root 2>&1 | Out-String
$routeOk = ($LASTEXITCODE -eq 0)
if ($routeOut.Trim()) { Write-Host $routeOut.Trim() }

if (-not $routeOk) {
    # Distinguish a BUSY recipient from a DEAD one before returning mail:
    # single-session CLIs fail a second wake while mid-session (exit 1 within
    # seconds), but their heartbeats are fresh. Busy => leave the copy in the
    # recipient's inbox for pickup when the session ends; dead => return.
    $peerDir = Join-Path $script:DirMailboxes $to
    $peerBusy = $false
    $procDir = Join-Path $peerDir 'processing'
    if (Test-Path -LiteralPath $procDir) {
        foreach ($pf in (Get-ChildItem -LiteralPath $procDir -File -Filter '*.progress' -ErrorAction SilentlyContinue)) {
            if ($pf.LastWriteTime -gt (Get-Date).AddMinutes(-30)) { $peerBusy = $true; break }
        }
        if (-not $peerBusy) {
            foreach ($pm in (Get-ChildItem -LiteralPath $procDir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
                if ($pm.LastWriteTime -gt (Get-Date).AddMinutes(-30)) { $peerBusy = $true; break }
            }
        }
    }
    if ($peerBusy) {
        # route requeued the copy into the recipient's inbox already - keep it
        Set-MailStatus -MessagePath $master -Status 'DELIVERED' | Out-Null
        Write-Journal -Agent $owner -Action 'SEND' -Detail ($id + ' | wake failed but recipient busy - queued in inbox for session-end pickup')
        Write-Host (Get-AkText 'send.queued-busy' 'QUEUED {0} -> {1} (recipient busy; will pick up when its session ends)' $id $to)
        exit 0
    }
    # Every channel failed and the recipient looks idle: pull the copy back out
    # of the recipient inbox (route requeued it there) together with its
    # dispatch sidecar, then return the mail to the sender. No silent retry -
    # the sender decides.
    $copyPath = Join-Path $targetInbox ($id + '.md')
    $copySide = Join-Path $targetInbox ($id + '.progress')
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-Path -LiteralPath $copyPath) { break }
        Start-Sleep -Milliseconds 300   # a racing router may re-claim briefly before requeuing
    }
    foreach ($p in @($copyPath, $copySide)) {
        for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $p); $i++) {
            try { [System.IO.File]::Delete($p) } catch { Start-Sleep -Milliseconds 300 }
        }
    }
    Set-MailStatus -MessagePath $master -Status 'RETURNED' -Reason 'all notify channels failed (recipient unreachable; see journal)'
    Write-Journal -Agent $owner -Action 'RETURN' -Detail ($id + ' | all notify channels failed')
    $body = (Get-AkLines 'send.allfailed.body' 'Your mail could not be delivered - every notify channel failed.' '' 'id: {0}' 'recipient: {1}' '' 'It was NOT queued for retry. Check the recipient card (wake chain), then hand the mail in again.' |
        ForEach-Object { $_ -f $id, $to }) -join "`r`n"
    $bounce = Write-SystemMail -To $owner -Topic $topic -Subject ('RETURNED ' + $id) -Body $body
    & (Join-Path $PSScriptRoot 'core\route.ps1') -File $bounce -Root $script:Root | Out-Null
    Write-Host (Get-AkText 'send.returned.all-channels-failed' 'RETURNED {0} -> {1} (all notify channels failed)' $id $owner)
    exit 0
}

# Delivered: stamp the master, ledger both copies.
Set-MailStatus -MessagePath $master -Status 'DELIVERED' | Out-Null
Add-ManifestEntry -Topic $topic -Path $master
Add-ManifestEntry -Topic $topic -Path $copy
Write-Journal -Agent $owner -Action 'SEND' -Detail ($id + ' | ' + $from + '->' + $to + ' | topic=' + $topic + ' | delivered')

# A delivered reply flips the requester's in-flight master to REPLIED (step 9).
if ($type -eq 'reply') {
    $orig = [string]$fm['in_reply_to']
    if ($orig) {
        $reqMaster = Join-Path (Get-SentDir -AgentName $to) ($orig + '.md')
        if (Test-Path -LiteralPath $reqMaster) {
            Set-MailStatus -MessagePath $reqMaster -Status 'REPLIED' | Out-Null
            Write-Journal -Agent $to -Action 'REPLIED' -Detail ($orig + ' <- ' + $id)
        }
    }
}

# Success receipt into the sender's inbox. sys-* mails are never auto-routed,
# so this wakes nobody; the status sidecar is the live view either way.
$receiptBody = (Get-AkLines 'send.receipt.body' 'Delivered to {0}.' '' 'id: {1}' 'Track it: read the .status sidecar next to the master in your sent area, or run scripts\mail-status.ps1 -Id {1}' |
    ForEach-Object { $_ -f $to, $id }) -join "`r`n"
if ($script:CreatedDriftNote) { $receiptBody += "`r`n`r`n" + $script:CreatedDriftNote }   # A6
$receipt = Write-SystemMail -To $owner -Topic $topic -Subject ('DELIVERED ' + $id) -Body $receiptBody
Write-Journal -Agent $owner -Action 'RECEIPT' -Detail ([System.IO.Path]::GetFileName($receipt))

Write-Host (Get-AkText 'send.delivered' 'DELIVERED {0} -> {1}' $id $to)
