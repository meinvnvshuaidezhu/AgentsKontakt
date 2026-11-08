param(
  [Parameter(Mandatory=$true)][string]$File,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

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

function Return-Mail {
    # Park the master in the owner's sent area, stamp RETURNED + reason,
    # drop a bounce system mail and route it (the sender must act). Never throws.
    param([string]$Path, [string]$Reason, [string]$Topic, [string]$ToAgent, [string]$MsgId)
    try {
        $master = Move-Atomic -File $Path -DestDir (Get-SentDir -AgentName $ToAgent)
        Set-MailStatus -MessagePath $master -Status 'RETURNED' -Reason $Reason -Topic $Topic | Out-Null
        Write-Journal -Agent $ToAgent -Action 'RETURN' -Detail ($MsgId + ' | ' + $Reason)
        $body = (Get-AkLines 'send.bounce.body' 'Your outbox mail was returned by the post office.' '' 'id: {0}' 'reason: {1}' '' 'The master copy is in your sent area (status RETURNED). Fix the problem and hand it in again.' |
            ForEach-Object { $_ -f $MsgId, $Reason }) -join "`r`n"
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
foreach ($k in @('id','topic','from','to','type','created')) {
    if (-not ($fm.ContainsKey($k)) -or [string]::IsNullOrWhiteSpace([string]$fm[$k])) {
        Return-Mail -Path $File -Reason ('bad envelope: missing ' + $k) -Topic ([string]$fm['topic']) -ToAgent $owner -MsgId $fallbackId
        Write-Host (Get-AkText 'send.returned.bad-envelope' 'RETURNED (bad envelope: missing {0})' $k)
        exit 0
    }
}
$id = [string]$fm['id']; $from = [string]$fm['from']; $to = [string]$fm['to']
$type = [string]$fm['type']; $topic = [string]$fm['topic']

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
        Return-Mail -Path $File -Reason ('related topic not found in archive: ' + $rel) -Topic $topic -ToAgent $owner -MsgId $id
        Write-Host (Get-AkText 'send.returned.related-not-found' 'RETURNED {0} (related topic not found)' $id)
        exit 0
    }
}

# Gates passed: master into the sender's sent area, then copy-deliver.
$sentDir = Get-SentDir -AgentName $owner
$master = Move-Atomic -File $File -DestDir $sentDir
Set-MailStatus -MessagePath $master -Status 'DISPATCHING' -Topic $topic -Peer $to | Out-Null
Write-Journal -Agent $owner -Action 'TAKE' -Detail ($id + ' | ' + $from + '->' + $to + ' | topic=' + $topic + ' | ' + $type)

$copy = Copy-MailAtomic -File $master -DestDir $targetInbox

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
$receipt = Write-SystemMail -To $owner -Topic $topic -Subject ('DELIVERED ' + $id) -Body $receiptBody
Write-Journal -Agent $owner -Action 'RECEIPT' -Detail ([System.IO.Path]::GetFileName($receipt))

Write-Host (Get-AkText 'send.delivered' 'DELIVERED {0} -> {1}' $id $to)
