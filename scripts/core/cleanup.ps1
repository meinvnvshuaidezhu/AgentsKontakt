param(
  [int]$TmpMinutes   = 10,
  [int]$StaleMinutes = 30,
  [int]$LiveMinutes  = 15,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        # the script may sit in a subdir - walk up to the data root (a dir holding registry\)
        $d = $PSScriptRoot
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if ($d) { $Root = $d } elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
        else { $Root = (Get-Location).Path }
    }
}
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Tree   # self-heal data dirs: a fresh root (or a pruned one) must not kill the sweep

$now = Get-Date

# ---- log hygiene: size rotation + mirror expiry (v2.1) ----
# Journals and service logs grow without bound (26MB of stale mirror transcripts
# accumulated by 2026-10); tunables live in config\system.json.
$cfg       = Get-SystemConfig
$sizeMb    = [long]([double]$cfg['rotate_size_mb'])
$keep      = [int]$cfg['rotate_keep']
$streamAge = [double]$cfg['stream_retention_days']
$sysDays   = [int]([double]$cfg['sys_retention_days'])

function Rotate-LogFile {
    # journal.log -> journal-<ts>.log once over $SizeMb; keep newest $Keep rotations.
    param([string]$Path, [long]$SizeMb, [int]$Keep)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt ($SizeMb * 1MB)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rotated = Join-Path $item.DirectoryName ($item.BaseName + '-' + $stamp + $item.Extension)
    Move-AtomicTo -File $item.FullName -DestPath $rotated | Out-Null
    Write-SystemLog ('log rotated (' + [Math]::Round($item.Length / 1MB, 1) + 'MB): ' + $item.Name + ' -> ' + [System.IO.Path]::GetFileName($rotated))
    $filter = $item.BaseName + '-*' + $item.Extension
    $old = @(Get-ChildItem -LiteralPath $item.DirectoryName -File -Filter $filter -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending)
    for ($i = $Keep; $i -lt $old.Count; $i++) {
        Remove-Item -LiteralPath $old[$i].FullName -Force
        Write-SystemLog ('log rotation pruned: ' + $old[$i].Name)
    }
}

# v2.2: directory probes cost ~50ms each on this volume, so every recurring
# walk here uses direct .NET enumeration - same probe count, no cmdlet
# overhead, identical semantics.

$logFiles = @()
foreach ($p in [System.IO.Directory]::GetFiles($script:DirLogs, '*.log')) {
    $logFiles += New-Object System.IO.FileInfo($p)
}
foreach ($sub in [System.IO.Directory]::GetDirectories($script:DirLogs)) {
    foreach ($p in [System.IO.Directory]::GetFiles($sub, '*.log')) {
        $logFiles += New-Object System.IO.FileInfo($p)
    }
}
foreach ($lf in $logFiles) {
    if ($lf.Name -match '-\d{8}-\d{6}\.log$') { continue }   # already a rotation
    Rotate-LogFile -Path $lf.FullName -SizeMb $sizeMb -Keep $keep
}

# Session mirror transcripts (wake-wrapper live views): convenience-only
# live views - the compressed originals stay in each agent's own storage.
# Registry cards document 7-day expiry; this actually enforces it. Any
# agent's mirror directory under logs\ is swept the same way.
foreach ($md in (Get-ChildItem -LiteralPath $script:DirLogs -Directory -ErrorAction SilentlyContinue)) {
    foreach ($f in (Get-ChildItem -LiteralPath $md.FullName -File -Filter 'stream-*.jsonl' -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $now.AddDays(-$streamAge)) {
            Remove-Item -LiteralPath $f.FullName -Force
            Write-SystemLog ('expired session mirror (age > ' + $streamAge + 'd): ' + $md.Name + '\' + $f.Name)
        }
    }
}

# Orphan .tmp files (crashed writers)
$tmps = @()
try {
    foreach ($p in [System.IO.Directory]::EnumerateFiles($script:DirMailboxes, '*.tmp', [System.IO.SearchOption]::AllDirectories)) {
        $tmps += New-Object System.IO.FileInfo($p)
    }
} catch {}
foreach ($f in $tmps) {
    if ($f.Exists -and $f.LastWriteTime -lt $now.AddMinutes(-$TmpMinutes)) {
        Remove-Item -LiteralPath $f.FullName -Force
        Write-SystemLog ('cleaned orphan tmp: ' + $f.FullName)
    }
}

# sys-* service mail retention (v2.2): receipts and stall reports have no
# reply semantics, so an unread one is not a delivery failure - requeueing
# it only fed the wake cycle, and unbounded it piled up (150 by 2026-10-29).
# Purge from every inbox at the configured age, together with the dispatch
# sidecar and with sidecar orphans whose letter is long gone (the route claim
# used to leave inbox\<id>.progress behind on every requeue cycle).
if ($sysDays -gt 0) {
    $cutoffSys = $now.AddDays(-$sysDays)
    foreach ($d in (Get-ChildItem -LiteralPath $script:DirMailboxes -Directory -ErrorAction SilentlyContinue)) {
        $inb = Join-Path $d.FullName 'inbox'
        if (-not (Test-Path -LiteralPath $inb)) { continue }
        foreach ($p in [System.IO.Directory]::GetFiles($inb, 'sys-*.md')) {
            $f = New-Object System.IO.FileInfo($p)
            if (-not $f.Exists) { continue }
            if ($f.LastWriteTime -lt $cutoffSys) {
                $sideS = Join-Path $inb ([System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.progress')
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $sideS) { Remove-Item -LiteralPath $sideS -Force -ErrorAction SilentlyContinue }
                Write-SystemLog ('expired sys mail (age > ' + $sysDays + 'd): ' + $d.Name + '\' + $f.Name)
            }
        }
        foreach ($p in [System.IO.Directory]::GetFiles($inb, '*.progress')) {
            $f = New-Object System.IO.FileInfo($p)
            if (-not $f.Exists) { continue }
            $mdS = Join-Path $inb ([System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.md')
            if (Test-Path -LiteralPath $mdS) { continue }
            if ($f.LastWriteTime -lt $cutoffSys) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-SystemLog ('expired orphan sidecar (age > ' + $sysDays + 'd): ' + $d.Name + '\' + $f.Name)
            }
        }
    }
}

# Stale processing (claimed but never answered): requeue into inbox — unless
# the agent is alive, i.e. a <id>.progress heartbeat was touched recently.
# Note: long-running agent work can legitimately exceed this window; the
# requeue is safe (idempotent claim) but tune -StaleMinutes if needed.
foreach ($d in (Get-ChildItem -LiteralPath $script:DirMailboxes -Directory -ErrorAction SilentlyContinue)) {
    $proc = Join-Path $d.FullName 'processing'
    if (-not (Test-Path -LiteralPath $proc)) { continue }
    foreach ($p in [System.IO.Directory]::GetFiles($proc, '*.md')) {
        $f = New-Object System.IO.FileInfo($p)
        if (-not $f.Exists -or $f.LastWriteTime -ge $now.AddMinutes(-$StaleMinutes)) { continue }
        # Service mails never get a reply, so a stale one is not a failure to
        # answer - requeueing it only fed the wake cycle. Purge on retention
        # instead (same age rule as the inbox pass above).
        if ($f.Name -like 'sys-*') {
            if ($sysDays -gt 0 -and $f.LastWriteTime -lt $now.AddDays(-$sysDays)) {
                $sideS = Join-Path $proc ([System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.progress')
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $sideS) { Remove-Item -LiteralPath $sideS -Force -ErrorAction SilentlyContinue }
                Write-SystemLog ('expired sys mail (age > ' + $sysDays + 'd): ' + $d.Name + '\' + $f.Name)
            }
            continue
        }
        $side = Join-Path $proc ([System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.progress')
        # ---- A4 (pdup-S1, t-20261107-pdup; workbuddy-verified conditions) ----
        # The sidecar STATUS line is the dispatch terminal state the PROTOCOL
        # promises ("邮局据此区分瞬时错误自动重排与配额类停止重试") - cleanup
        # never read it, so an ANSWERED letter cycled requeue -> claim -> wake
        # three times and cooked a fake RETURNED (2026-11-06 night, hermes
        # k7m2: three full re-reviews, three contradictory replies).
        #   - Only "^STATUS ok" is terminal (real value: "STATUS ok via exec" -
        #     prefix match, not -eq). "STATUS failed" is a LAUNCH failure and
        #     must keep the normal requeue path, or a failed dispatch would sit
        #     in processing forever.
        #   - PULL recipients (wake: TODO) never get a STATUS line: their claim
        #     is their own mail-check pickup, so a requeue would only re-show
        #     the letter in their inbox (and steal it back mid-session - the
        #     2026-11-08 zcode reclaim loop). Skip those too. Known limitation
        #     (documented in the A4 letter): a PULL agent that dies mid-work
        #     leaves the letter in processing with no requeue recovery - the
        #     long-term fix is the single-letter ack (pdup-S3, phase B).
        # Log-once via a routed flag: a terminal letter hits this branch on
        # EVERY sweep forever, and per-sweep logging would drown system.log.
        $stLine = ''
        if (Test-Path -LiteralPath $side) {
            foreach ($ln in [System.IO.File]::ReadAllLines($side)) {
                if ($ln -match '^STATUS') { $stLine = $ln }
            }
        }
        $pullRecipient = $false
        $cardPath4 = Join-Path $script:DirRegistry ($d.Name + '.md')
        if (Test-Path -LiteralPath $cardPath4) {
            $w4 = [string](Read-FrontMatter -Path $cardPath4)['wake']
            if (-not $w4 -or $w4 -match 'TODO') { $pullRecipient = $true }
        }
        if (($stLine -match '^STATUS ok') -or $pullRecipient) {
            $flagKey = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.terminal'
            if (-not (Test-RouteFlag -MessageId $flagKey)) {
                Set-RouteFlag -MessageId $flagKey
                $why = if ($stLine -match '^STATUS ok') { 'sidecar STATUS ok' } else { 'PULL recipient (wake TODO)' }
                Write-SystemLog ('TERMINAL skip requeue (' + $why + '): ' + $d.Name + '\' + $f.Name)
                Write-Journal -Agent $d.Name -Action 'STATE' -Detail ('terminal skip requeue (' + $why + '): ' + $f.Name)
            }
            continue
        }
        $alive = $false
        $aliveVia = ''
        if (Test-Path -LiteralPath $side) {
            if ((Get-Item -LiteralPath $side).LastWriteTime -gt $now.AddMinutes(-$LiveMinutes)) { $alive = $true; $aliveVia = 'heartbeat' }
        }        if (-not $alive) {
            # Dual-track liveness (v2): the agent's thinking record in their
            # notes area also counts as activity. The post office only reads
            # mtimes - never the notes content.
            $fm = Read-FrontMatter -Path $f.FullName
            $topic = [string]$fm['topic']
            if ($topic) {
                $note = Join-Path (Join-Path $d.FullName 'notes') ($topic + '.md')
                if (Test-Path -LiteralPath $note) {
                    if ((Get-Item -LiteralPath $note).LastWriteTime -gt $now.AddMinutes(-$LiveMinutes)) { $alive = $true; $aliveVia = 'notes' }
                }
            }
        }
        if ($alive) {
            # A fresh heartbeat is the normal state of a working agent -
            # logging it every sweep only grew system.log (5 lines per sweep
            # while the requeue cycle lived). The notes save is the
            # interesting case; keep that one visible.
            if ($aliveVia -eq 'notes') {
                Write-SystemLog ('skip requeue (notes fresh): ' + $d.Name + '\' + $f.Name)
            }
            continue
        }
        $inbox = Join-Path (Split-Path $proc -Parent) 'inbox'
        Move-Atomic -File $f.FullName -DestDir $inbox | Out-Null
        # carry the progress notes back with the message for the next handler
        if (Test-Path -LiteralPath $side) {
            Move-Atomic -File $side -DestDir $inbox | Out-Null
        }
        Write-SystemLog ('WARN requeued stale processing after ' + $StaleMinutes + 'min: ' + $d.Name + '\' + $f.Name)
    }
}

# Prune old routed-flags (they only exist to keep WARN-once semantics)
if (Test-Path -LiteralPath $script:DirRouted) {
    foreach ($p in [System.IO.Directory]::GetFiles($script:DirRouted, '*.flag')) {
        $f = New-Object System.IO.FileInfo($p)
        if ($f.Exists -and $f.LastWriteTime -lt $now.AddDays(-7)) { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

# v2: cold-store expired thinking records. Per the approved policy a note
# lives while the topic is open, then keep-days past its close (card field
# think_retention, default 90), then gets zipped into post\cold. This is the
# one sanctioned post-office touch of the notes area - expired drafts only;
# conclusions already live in the summary (the permanent layer).
$summaryIndex = @{}
try {
    foreach ($s in [System.IO.Directory]::EnumerateFiles($script:DirArchive, 'summary.md', [System.IO.SearchOption]::AllDirectories)) {
        $t = Split-Path (Split-Path $s -Parent) -Leaf
        $summaryIndex[$t] = $s
    }
} catch {}
foreach ($d in (Get-ChildItem -LiteralPath $script:DirMailboxes -Directory -ErrorAction SilentlyContinue)) {
    $notes = Join-Path $d.FullName 'notes'
    if (-not (Test-Path -LiteralPath $notes)) { continue }
    $agent = $d.Name
    $card = Join-Path $script:DirRegistry ($agent + '.md')
    $keepDays = 90
    if (Test-Path -LiteralPath $card) {
        $cfm = Read-FrontMatter -Path $card
        $v = [string]$cfm['think_retention']
        if ($v -match '^\d+$') { $keepDays = [int]$v }
    }
    foreach ($p in [System.IO.Directory]::GetFiles($notes, '*.md')) {
        $f = New-Object System.IO.FileInfo($p)
        if (-not $f.Exists) { continue }
        $t = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if (-not $summaryIndex.ContainsKey($t)) { continue }   # topic not closed - keep
        $sfm = Read-FrontMatter -Path $summaryIndex[$t]
        $closed = $null
        try { $closed = [datetime]::Parse([string]$sfm['closed']) } catch {}
        if (-not $closed) { continue }
        if ($closed.AddDays($keepDays) -ge $now) { continue }   # still inside the window
        $cold = Join-Path $script:DirCold ($agent + '-' + $t + '.zip')
        $dir = Split-Path $cold -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Compress-Archive -LiteralPath $f.FullName -DestinationPath $cold -Force
        Remove-Item -LiteralPath $f.FullName -Force
        Write-SystemLog ('thinking record cold-stored (closed ' + $closed.ToString('yyyy-MM-dd') + ', keep ' + $keepDays + 'd): ' + $agent + '\' + $f.Name)
    }
}


# ---- v3 topic state machine sweep (r4.1 §5) ----
# Walks post\threads\<topic>\status.json and drives every time-based rule:
#   pending   > 5min since delivery        -> one-shot "not picked up" note
#   pending   > pending_stall_minutes      -> one-shot "close or redirect" nudge
#   processing + heartbeat AND notes dead  -> demote to pending (+ sys mail both)
#   answered  >= nudge_after_days          -> one-shot three-party nudge
#   answered  >= auto_archive_after_days   -> auto archive (post office closes)
$threadsRoot = Join-Path $script:DirPost 'threads'
$nudgeDays   = [double]$cfg['nudge_after_days']
$autoDays    = [double]$cfg['auto_archive_after_days']
$pendStall   = [int]$cfg['pending_stall_minutes']
if (Test-Path -LiteralPath $threadsRoot) {
    foreach ($sd in (Get-ChildItem -LiteralPath $threadsRoot -Directory -ErrorAction SilentlyContinue)) {
        $sp = Join-Path $sd.FullName 'status.json'
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        $st = $null
        try { $st = [System.IO.File]::ReadAllText($sp) | ConvertFrom-Json } catch { continue }
        $t = [string]$st.topic; $state = [string]$st.state
        $from = [string]$st.from; $to = [string]$st.to
        $nowStamp = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        if ($state -eq 'pending') {
            $delivered = $null
            try { $delivered = [datetime]::Parse([string]$st.delivered_at) } catch {}
            if ($delivered) {
                $ageMin = ($now - $delivered).TotalMinutes
                if ($ageMin -ge 5 -and -not $st.pickup_nudged) {
                    $body = 'Topic ' + $t + ' is still pending after ' + [int]$ageMin + ' minutes (' + $to + ' has not claimed it). Informational note only - the copy waits in their inbox.'
                    $null = Write-SystemMail -To $from -Topic $t -Subject ('PENDING ' + $t) -Body $body
                    $null = Set-TopicStatus -Topic $t -Fields @{ pickup_nudged = $nowStamp }
                    Write-SystemLog ('v3: pending pickup nudge sent: ' + $t)
                }
                if ($ageMin -ge $pendStall -and -not $st.redirect_nudged) {
                    $body = 'Topic ' + $t + ' has been pending for ' + [int]$ageMin + ' minutes and ' + $to + ' has not claimed it. Options: close the topic, or redirect it: send.ps1 -Redirect -Topic ' + $t + ' -RedirectTo <agent>'
                    $null = Write-SystemMail -To $from -Topic $t -Subject ('PENDING-STALL ' + $t) -Body $body
                    $null = Set-TopicStatus -Topic $t -Fields @{ redirect_nudged = $nowStamp }
                    Write-Journal -Agent 'postmaster' -Action 'STATE' -Detail ($t + ' pending-stall nudge (' + [int]$ageMin + 'min)')
                }
            }
        }
        if ($state -eq 'processing') {
            $hb = $null
            try { $hb = [datetime]::Parse([string]$st.last_heartbeat) } catch {}
            $hbFresh = $false
            if ($hb -and (($now - $hb).TotalMinutes -lt $StaleMinutes)) { $hbFresh = $true }
            if (-not $hbFresh) {
                $notesDir = Join-Path (Join-Path $script:DirMailboxes $to) 'notes'
                if (Test-Path -LiteralPath $notesDir) {
                    foreach ($nf in [System.IO.Directory]::GetFiles($notesDir)) {
                        $fi = New-Object System.IO.FileInfo($nf)
                        if ($fi.LastWriteTime -gt $now.AddMinutes(-$StaleMinutes)) { $hbFresh = $true; break }
                    }
                }
            }
            if (-not $hbFresh) {
                $null = Set-TopicStatus -Topic $t -Fields @{ state = 'pending'; state_updated_by = 'postmaster'; state_updated_at = $nowStamp }
                Write-Journal -Agent 'postmaster' -Action 'STATE' -Detail ($t + ' demoted processing->pending (no heartbeat, no notes activity for ' + $StaleMinutes + 'min)')
                $body = 'Topic ' + $t + ' was demoted back to pending: the responder stopped heartbeating and shows no notes activity for ' + $StaleMinutes + ' minutes. The chain copy stays in their inbox for re-claim.'
                foreach ($a in @($from, $to)) { if ($a) { $null = Write-SystemMail -To $a -Topic $t -Subject ('DEMOTED ' + $t) -Body $body } }
                Write-SystemLog ('v3: stalled processing demoted to pending: ' + $t)
            }
        }
        if ($state -eq 'answered') {
            $ansAt = $null
            try { $ansAt = [datetime]::Parse([string]$st.state_updated_at) } catch {}
            if ($ansAt) {
                $days = ($now - $ansAt).TotalDays
                if ($days -ge $nudgeDays -and -not $st.nudged) {
                    $body = 'Topic ' + $t + ' has been answered for ' + [int]$days + ' days without the initiator archiving it (owner cc). It will auto-archive at ' + [int]$autoDays + ' days after answered (config: auto_archive_after_days).'
                    foreach ($a in @($from, $to)) { if ($a) { $null = Write-SystemMail -To $a -Topic $t -Subject ('NUDGE ' + $t) -Body $body } }
                    $null = Set-TopicStatus -Topic $t -Fields @{ nudged = $nowStamp }
                    Write-SystemLog ('v3: answered-age nudge sent (owner cc): ' + $t)
                }
                if ($days -ge $autoDays) {
                    $dest = Invoke-TopicArchive -Topic $t -ClosedBy 'postmaster'
                    foreach ($a in @($from, $to)) {
                        if ($a) {
                            $null = Clear-ThreadCopies -Topic $t -Agent $a
                            $null = Write-SystemMail -To $a -Topic $t -Subject ('ARCHIVED ' + $t) -Body ('Topic ' + $t + ' was auto-archived (answered for ' + [int]$days + ' days with no initiator action). Archive: ' + $dest)
                        }
                    }
                    Write-SystemLog ('v3: auto-archived after ' + [int]$days + 'd answered: ' + $t)
                    Update-Dashboard
                }
            }
        }
    }
}


# ---- v3 orphan trash sweep (n5w8 R1/R3) ----
# R1: the full orphan scan is throttled (orphan_scan_interval_minutes, default
# 60, gate = post\trash\.lastscan mtime) - it walks every thread dir and the
# archive tree and must not eat the sweep's CPU budget. The sweep cpu ms
# accounting keeps its existing shape: the orphan pass runs as a child script.
# R3: expiry purge is NOT throttled - a one-shot expires_at compare, and the
# 7-day promise must not slip by hours.
$trashDir = Join-Path $script:DirPost 'trash'
if (-not (Test-Path -LiteralPath $trashDir)) { New-Item -ItemType Directory -Path $trashDir -Force | Out-Null }
$orphanScan = Join-Path $PSScriptRoot '..\orphan-scan.ps1'
if (Test-Path -LiteralPath $orphanScan) {
    $interval = 60
    try { if ([string]$cfg['orphan_scan_interval_minutes'] -match '^\d+$') { $interval = [int]$cfg['orphan_scan_interval_minutes'] } } catch {}
    $lastscan = Join-Path $trashDir '.lastscan'
    $due = $true
    if (Test-Path -LiteralPath $lastscan) {
        if (((Get-Date) - (Get-Item -LiteralPath $lastscan).LastWriteTime).TotalMinutes -lt $interval) { $due = $false }
    }
    if ($due) {
        $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $orphanScan -MoveToTrash -Root $script:Root 2>&1
        Write-SystemLog ('v3: orphan scan ran (throttle window ' + $interval + 'min)')   # .lastscan stamped by the scan itself
    }
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $orphanScan -Purge -Root $script:Root 2>&1
}

