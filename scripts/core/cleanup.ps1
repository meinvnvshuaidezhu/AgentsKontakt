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
