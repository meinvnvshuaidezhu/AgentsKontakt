param(
  [switch]$Quiet,
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

# ---- change gate: skip the full rebuild when nothing we read has moved -------
# The sweep calls this every 60s and a full pass reads every message body in
# every mailbox plus the whole archive (~0.7 CPU-s here). The metadata-only
# walk below costs a few percent of that. Fingerprint = template stamp plus
# every remaining file's (length, mtime) under mailboxes\ registry\ archive\.
# Files the renderer ignores (summary.md, tmp/part/bak) are excluded so their
# churn cannot trigger rebuilds.
$dashDir0 = Join-Path $Root 'dashboard'
# Crash leftovers (per-PID tmp/bak from interrupted writes): prune anything
# older than an hour so the directory cannot accrete debris.
try {
    if (Test-Path -LiteralPath $dashDir0) {
        foreach ($f in [System.IO.Directory]::GetFiles($dashDir0)) {
            $n = [System.IO.Path]::GetFileName($f)
            if ($n -like '*.tmp' -or $n -like '*.bak') {
                $fi = New-Object System.IO.FileInfo($f)
                if ($fi.Exists -and ((Get-Date) - $fi.LastWriteTime).TotalHours -gt 1) {
                    try { [System.IO.File]::Delete($f) } catch {}
                }
            }
        }
    }
} catch {}
$dataJs = Join-Path $dashDir0 'dashboard-data.js'
$dataHtml = Join-Path $dashDir0 'dashboard.html'
$fpFile = Join-Path $dashDir0 'dashboard-data.fp'
$tplStamp = ''
$tplPath = Join-Path $script:DirTemplates 'dashboard-template.html'
if (Test-Path -LiteralPath $tplPath) {
    $ti = Get-Item -LiteralPath $tplPath
    $tplStamp = '{0}:{1}' -f $ti.Length, $ti.LastWriteTimeUtc.Ticks
}
Ensure-AkScan   # compiled walk: the same pass in a PS loop costs ~3x more
$roots = @((Join-Path $Root 'mailboxes'), (Join-Path $Root 'registry'), (Join-Path $Root 'archive'))
$fp = ''
try { $fp = [AkScan]::Fingerprint($roots) } catch { $fp = '' }   # walk failed: fingerprint unknown, force a rebuild
# Mix in the template stamp: the header comment always promised it, but it was
# only ever computed - never appended - so template edits alone never triggered
# a rebuild.
$fp = 'tpl:' + $tplStamp + ';' + $fp
# liveness heartbeat (v2.3.4): written on EVERY call - even when the fingerprint
# gate skips the rebuild - so the panel can tell an idle-but-alive postman from
# a dead one (idle post offices previously showed 邮差未响应).
$seqFile = Join-Path $dashDir0 'dashboard-seq.js'
try {
    $seqVal = ''
    if (Test-Path -LiteralPath $seqFile) {
        $m = [regex]::Match([System.IO.File]::ReadAllText($seqFile), '"(\d+)"')
        if ($m.Success) { $seqVal = $m.Groups[1].Value }
    }
    [System.IO.File]::WriteAllText($seqFile, 'window.DASHBOARD_SEQ = "' + $seqVal + '"; window.DASHBOARD_HEARTBEAT = "' + (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") + '";')
} catch {}
if ($fp.Length -gt 0 -and (Test-Path -LiteralPath $fpFile) -and (Test-Path -LiteralPath $dataJs) -and (Test-Path -LiteralPath $dataHtml)) {
    $lastFp = $null
    try { $lastFp = [System.IO.File]::ReadAllText($fpFile) } catch {}
    if ($lastFp -eq $fp) { exit 0 }   # nothing moved: the panel already has current data
}

# Dashboard generator. Emits two files:
#   dashboard.html      - static shell (self-rendering UI, see template)
#   dashboard-data.js   - window.DASHBOARD_DATA = {...}; the shell polls this
#                         every 2s (script-tag injection works over file://).
# The view is zcode-centric: chats group messages exchanged between zcode and
# each other registered agent. Heartbeat freshness is recomputed client-side.

$LocalAgent = 'zcode'
if ($null -eq $global:DashBodyCache) { $global:DashBodyCache = @{} }
if ($null -eq $global:DashFmCache)   { $global:DashFmCache = @{} }
$agents = Get-RegisteredAgents
$now = Get-Date

function Get-Iso {
    param([datetime]$t)
    return $t.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}

function Get-BodyText {
    # Versioned body cache (per daemon process): archive letters never change,
    # live letters only re-read when len+mtime move. The watch loop runs this
    # script in-process, so $global: persists across sweeps.
    # -MaxLen truncates the returned body (payload diet): the cache stores the
    # truncated text, so a trimmed archive letter never costs a full read again.
    # Returns @{ body = <text>; truncated = <bool> }.
    param([string]$Path, [int]$MaxLen = 0)
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists) { return @{ body = ''; truncated = $false } }
        $key = $fi.FullName + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
        $v = $global:DashBodyCache[$key]
        if ($null -ne $v) { return $v }
        if ($global:DashBodyCache.Count -gt 3000) { $global:DashBodyCache.Clear() }
        $t = [System.IO.File]::ReadAllText($Path)
        if ($t -match '(?s)\A---\r?\n.*?\r?\n---\s*(\r?\n)?') { $t = $t.Substring($Matches[0].Length) }
        $t = $t -replace '(?m)^##\s*正文\s*\r?\n', ''
        $t = $t.Trim()
        $trunc = $false
        if ($MaxLen -gt 0 -and $t.Length -gt $MaxLen) {
            $t = $t.Substring(0, $MaxLen).TrimEnd() + ' …'
            $trunc = $true
        }
        $entry = @{ body = $t; truncated = $trunc }
        $global:DashBodyCache[$key] = $entry
        return $entry
    } catch { return @{ body = ''; truncated = $false } }
}

function Get-CachedFm {
    # Versioned front-matter cache - same lifecycle as the body cache.
    param([string]$Path)
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists) { return @{} }
        $key = $fi.FullName + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
        $v = $global:DashFmCache[$key]
        if ($null -ne $v) { return $v }
        if ($global:DashFmCache.Count -gt 3000) { $global:DashFmCache.Clear() }
        $fm = Read-FrontMatter -Path $Path
        $global:DashFmCache[$key] = $fm
        return $fm
    } catch { return @{} }
}

function Get-CachedMailStatus {
    # Versioned status-sidecar cache for the in-flight map.
    param([string]$MessagePath)
    try {
        $side = [System.IO.Path]::ChangeExtension($MessagePath, '.status')
        $fi = New-Object System.IO.FileInfo($side)
        if (-not $fi.Exists) { return @{} }
        $key = $fi.FullName + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
        $v = $global:DashFmCache[$key]
        if ($null -ne $v) { return $v }
        if ($global:DashFmCache.Count -gt 3000) { $global:DashFmCache.Clear() }
        $st = Get-MailStatus -MessagePath $MessagePath
        $global:DashFmCache[$key] = $st
        return $st
    } catch { return @{} }
}

# Browser pages poll these files every 2s (and events fire while they are being
# read), so writes must be atomic: tmp file + NTFS Replace, never truncate-in-place.
function Write-DashFile {
    param([string]$Path, [string]$Content)
    # Per-PID tmp AND backup names: route/send children and the watch loop all
    # regenerate the panel concurrently, and shared names made them stomp each
    # other ("file in use by another process", Replace moving the dest under
    # the other writer's backup) on every busy burst. Never rethrows - this
    # runs inside the watch sweep, which a thrown race used to abort mid-stage.
    $tmp = '{0}.{1}.tmp' -f $Path, $PID
    $bak = '{0}.{1}.bak' -f $Path, $PID
    [System.IO.File]::WriteAllText($tmp, $Content, $script:UTF8Bom)
    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmp, $Path, $bak)
            if (Test-Path -LiteralPath $bak) { [System.IO.File]::Delete($bak) }
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        # Replace race fallout: the dest may already sit under our backup name
        # (ERROR_UNABLE_TO_MOVE_REPLACEMENT leaves no dest in place). Restore
        # the old content, then complete with delete+move - a tiny non-atomic
        # window that only ever runs in this degraded path.
        try {
            if (-not (Test-Path -LiteralPath $Path)) {
                if (Test-Path -LiteralPath $bak) { [System.IO.File]::Move($bak, $Path) }
            } elseif (Test-Path -LiteralPath $bak) {
                [System.IO.File]::Delete($bak)
            }
            if (Test-Path -LiteralPath $tmp) {
                if (Test-Path -LiteralPath $Path) { [System.IO.File]::Delete($Path) }
                [System.IO.File]::Move($tmp, $Path)
            }
        } catch {
            try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch {}
        }
    }
}

function Get-ProgressInfo {
    # returns $null or @{ last = ISO; note = last heartbeat line }
    param([string]$MsgPath)
    $side = Join-Path (Split-Path $MsgPath -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($MsgPath) + '.progress')
    if (-not (Test-Path -LiteralPath $side)) { return $null }
    $item = New-Object System.IO.FileInfo($side)
    $note = ''
    try {
        $lines = [System.IO.File]::ReadAllLines($side) | Where-Object { $_.Trim() -ne '' }
        if ($lines) { $note = [string]$lines[-1] }
    } catch {}
    return @{ last = (Get-Iso $item.LastWriteTime); note = $note }
}

# ---- per-message progress heartbeats in every processing folder
$progressMap = @{}
foreach ($a in $agents) {
    $agentDir = Split-Path (Join-Path $Root ([string]$a.inbox)) -Parent
    $proc = Join-Path $agentDir 'processing'
    if (-not (Test-Path -LiteralPath $proc)) { continue }
    foreach ($p in [System.IO.Directory]::GetFiles($proc, '*.md')) {
        $pi = Get-ProgressInfo -MsgPath $p
        if ($pi) { $progressMap[[System.IO.Path]::GetFileNameWithoutExtension($p)] = $pi }
    }
}

function Get-AgentHeartbeat {
    # freshest heartbeat across an agent's processing folder (ISO or $null)
    param([string]$AgentName)
    $agentDir = Split-Path (Join-Path $Root (($agents | Where-Object { $_.name -eq $AgentName }).inbox)) -Parent
    $proc = Join-Path $agentDir 'processing'
    $fresh = $null
    if (Test-Path -LiteralPath $proc) {
        foreach ($p in [System.IO.Directory]::GetFiles($proc, '*.progress')) {
            $fi = New-Object System.IO.FileInfo($p)
            if ($fi.Exists -and (-not $fresh -or $fi.LastWriteTime -gt $fresh)) { $fresh = $fi.LastWriteTime }
        }
    }
    if ($fresh) { return (Get-Iso $fresh) }
    return $null
}

function Get-AgentStreamTail {
    # declared thinking-stream tail for the dashboard (v2.2 W5): parse the
    # card's liveness `stream=<glob>` (progress-only => none), resolve the
    # freshest matching file, return its last lines. Static display: refreshed
    # on dashboard regeneration only (logs are not in the change fingerprint),
    # deliberately not a live tail. Cost is bounded: only stream-declaring
    # agents are read, tail-capped.
    param([string]$Liveness)
    if (-not $Liveness -or $Liveness -notmatch 'stream=([^\s;（]+)') { return $null }
    $glob = $Matches[1]
    if (-not $glob -or $glob -eq 'progress-only' -or $glob -eq '无') { return $null }
    $glob = $glob -replace '<[^>]+>', '*'
    if (-not [System.IO.Path]::IsPathRooted($glob)) { $glob = Join-Path $Root $glob }
    $dir = Split-Path $glob -Parent
    $pat = Split-Path $glob -Leaf
    $best = $null
    try {
        foreach ($f in [System.IO.Directory]::GetFiles($dir, $pat)) {
            $fi = New-Object System.IO.FileInfo($f)
            if ($fi.Exists -and (-not $best -or $fi.LastWriteTime -gt $best.LastWriteTime)) { $best = $fi }
        }
    } catch { return $null }
    if (-not $best) { return $null }
    $lines = @()
    try {
        # Get-Content -Tail on a multi-MB-line JSONL costs tens of CPU-seconds
        # in PS 5.1 (measured 67s on a 19MB model-io log): it decodes backwards
        # from the seek point and rescans huge lines. Read the last 256KB raw
        # instead and split here - bounded cost no matter how long the lines
        # are. The per-line cap keeps the payload small too: one LLM request
        # dump line can carry megabytes (observed 2.6MB inside dashboard-data.js).
        if ($best.Length -le 0) { return $null }
        $cap = [Math]::Min($best.Length, 262144)
        $fs = [System.IO.File]::Open($best.FullName, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $null = $fs.Seek(-$cap, [System.IO.SeekOrigin]::End)
            $buf = New-Object byte[] $cap
            $off = 0
            while ($off -lt $cap) {
                $n = $fs.Read($buf, $off, $cap - $off)
                if ($n -le 0) { break }
                $off += $n
            }
        } finally { $fs.Dispose() }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $off)
        $parts = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($cap -lt $best.Length -and $parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] }   # first is a cut-off half line
        $lines = @($parts | Select-Object -Last 12 | ForEach-Object {
            if ($_.Length -gt 2000) { $_.Substring(0, 2000) + ' …' } else { $_ }
        })
    } catch { return $null }
    if (-not $lines.Count) { return $null }
    return [pscustomobject]@{
        file = $best.Name
        updated = (Get-Iso $best.LastWriteTime)
        tail = ($lines -join "`n")
    }
}

# ---- in-flight masters (v2): the sender's sent area + status sidecars ----
$inflightMap = @{}
foreach ($a in $agents) {
    $agentDir = Split-Path (Join-Path $Root ([string]$a.inbox)) -Parent
    $sent = Join-Path $agentDir 'sent'
    $items = @()
    if (Test-Path -LiteralPath $sent) {
        foreach ($p in [System.IO.Directory]::GetFiles($sent, '*.md')) {
            $st = Get-CachedMailStatus -MessagePath $p
            if (-not $st.Count) { continue }
            $items += [pscustomobject]@{
                id = [System.IO.Path]::GetFileNameWithoutExtension($p); status = [string]$st['status']
                reason = [string]$st['reason']; updated = [string]$st['updated']
                peer = [string]$st['peer']
            }
        }
    }
    $inflightMap[[string]$a.name] = $items
}

# ---- agents
$agentList = @()
foreach ($a in $agents) {
    $agentDir = Split-Path (Join-Path $Root ([string]$a.inbox)) -Parent
    $cin = 0
    $procDir = Join-Path $agentDir 'processing'
    if (Test-Path -LiteralPath (Join-Path $agentDir 'inbox')) {
        $cin = @([System.IO.Directory]::GetFiles((Join-Path $agentDir 'inbox'), '*.md')).Count
    }
    $hb = Get-AgentHeartbeat -AgentName $a.name
    $mode = if ([string]::IsNullOrWhiteSpace($a.wake) -or $a.wake -match 'TODO') { 'PULL' } else { 'PUSH' }
    $avatar = [string]$a.avatar
    if (-not $avatar) { $avatar = ([string]$a.name).Substring(0, 1).ToUpper() }
    $seen = $null
    if ([string]$a.last_seen -and [string]$a.last_seen -ne '(never)') {
        try { $seen = Get-Iso ([datetime]::Parse([string]$a.last_seen)) } catch {}
    }
    $statusText = '空闲'
    if ($hb) { $statusText = '处理中' }   # freshness is recomputed client-side
    if ($cin -gt 0 -and $statusText -eq '空闲') { $statusText = '有新信待处理' }
    $agentList += [pscustomobject]@{
        name = [string]$a.name; avatar = $avatar; mode = $mode
        contact = [string]$a.contact; lastSeen = $seen
        inboxCount = $cin; lastHeartbeat = $hb; statusText = $statusText
        inflight = $inflightMap[[string]$a.name]
        alertCount = @($inflightMap[[string]$a.name] | Where-Object { $_.status -in @('STALLED','RETURNED') }).Count
        stream = (Get-AgentStreamTail -Liveness ([string]$a.liveness))
    }
}

# ---- chats (zcode <-> each peer), messages from inbox/processing/archive
$chats = @{}
function Add-ChatMsg {
    param([string]$Path, [string]$State)
    $fm = Get-CachedFm -Path $Path
    $from = [string]$fm['from']; $to = [string]$fm['to']
    if (-not $from -or -not $to) { return }
    if ($from -eq $to) { return }
    $peer = $null
    if ($from -eq $LocalAgent) { $peer = $to } elseif ($to -eq $LocalAgent) { $peer = $from }
    if (-not $peer) { return }
    $created = $null
    try { $created = [datetime]::Parse([string]$fm['created']) } catch { $created = (Get-Item -LiteralPath $Path).LastWriteTime }
    $pi = $null
    if ($State -eq 'processing') { $pi = $progressMap[[string](Get-Item -LiteralPath $Path).BaseName] }
    # Payload diet: archived letters carry a snippet only. They are immutable
    # history and the archive grows forever - full bodies here made
    # dashboard-data.js (and the shell's poll of it) grow without bound.
    # trunc/arch let the shell show a "read the archive" hint instead of a
    # silently cut bubble.
    $bodyInfo = Get-BodyText -Path $Path -MaxLen $(if ($State -eq 'archive') { 240 } else { 0 })
    $archRel = $null
    if ($State -eq 'archive') { $archRel = $Path.Substring($script:DirArchive.Length + 1).Replace('\', '/') }
    $msg = [pscustomobject]@{
        id = [string]$fm['id']; topic = [string]$fm['topic']
        from = $from; to = $to; type = [string]$fm['type']
        subject = [string]$fm['subject']
        created = (Get-Iso $created); state = $State; body = [string]$bodyInfo['body']
        trunc = [bool]$bodyInfo['truncated']; arch = $archRel
        lastProgress = if ($pi) { $pi.last } else { $null }
        lastProgressNote = if ($pi) { $pi.note } else { $null }
    }
    if (-not $chats.ContainsKey($peer)) { $chats[$peer] = @() }
    $chats[$peer] += $msg
}

$zc = $agents | Where-Object { $_.name -eq $LocalAgent }
if ($zc) {
    $zdir = Split-Path (Join-Path $Root ([string]$zc.inbox)) -Parent
    foreach ($st in @('inbox', 'processing')) {
        $d = Join-Path $zdir $st
        foreach ($p in [System.IO.Directory]::GetFiles($d, '*.md')) { Add-ChatMsg -Path $p -State $st }
    }
}
foreach ($a in $agents) {
    if ($a.name -eq $LocalAgent) { continue }
    $adir = Split-Path (Join-Path $Root ([string]$a.inbox)) -Parent
    foreach ($st in @('inbox', 'processing')) {
        $d = Join-Path $adir $st
        foreach ($p in [System.IO.Directory]::GetFiles($d, '*.md')) { Add-ChatMsg -Path $p -State $st }
    }
}
foreach ($p in [System.IO.Directory]::GetFiles($script:DirArchive, '*.md', [System.IO.SearchOption]::AllDirectories)) {
    if (([System.IO.Path]::GetFileName($p)) -eq 'summary.md') { continue }
    Add-ChatMsg -Path $p -State 'archive'
}

$chatList = @()
foreach ($peer in $chats.Keys) {
    $msgs = @($chats[$peer] | Sort-Object { [datetime]::Parse($_.created) })
    if ($msgs.Count -gt 200) { $msgs = @($msgs | Select-Object -Last 200) }   # payload diet: newest 200 per chat
    $last = $msgs[-1]
    $pAgent = $agents | Where-Object { $_.name -eq $peer }
    $pMode = if ($pAgent -and -not ([string]::IsNullOrWhiteSpace($pAgent.wake)) -and ([string]$pAgent.wake -notmatch 'TODO')) { 'PUSH' } else { 'PULL' }
    $pAvatar = if ($pAgent -and [string]$pAgent.avatar) { [string]$pAgent.avatar } else { $peer.Substring(0, 1).ToUpper() }
    $pContact = if ($pAgent) { [string]$pAgent.contact } else { '' }
    $pSeen = $null
    if ($pAgent -and [string]$pAgent.last_seen -and [string]$pAgent.last_seen -ne '(never)') {
        try { $pSeen = Get-Iso ([datetime]::Parse([string]$pAgent.last_seen)) } catch {}
    }
    $unread = @($msgs | Where-Object { $_.to -eq $LocalAgent -and $_.state -eq 'inbox' }).Count
    # 当前（最新）话题的提问方 = 最后一条 request 的 from（回信总是后到，逆序第一条 request 即最新话题的开题信）
    $initiator = $null
    for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
        if ($msgs[$i].type -eq 'request') { $initiator = $msgs[$i].from; break }
    }
    if (-not $initiator) { $initiator = $msgs[0].from }
    $peerWorking = @($msgs | Where-Object { $_.from -eq $LocalAgent -and $_.state -eq 'processing' -and $_.lastProgress }).Count
    $localWorking = @($msgs | Where-Object { $_.to -eq $LocalAgent -and $_.state -eq 'processing' -and $_.lastProgress }).Count
    $chatList += [pscustomobject]@{
        peer = $peer; avatar = $pAvatar; mode = $pMode; contact = $pContact; lastSeen = $pSeen
        unread = $unread; initiator = $initiator
        peerWorkingHint = $peerWorking; localWorkingHint = $localWorking
        lastTime = $last.created; lastSnippet = ([string]$last.body).Substring(0, [Math]::Min(60, ([string]$last.body).Length))
        messages = $msgs
    }
}
$chatList = @($chatList | Sort-Object { [datetime]::Parse($_.lastTime) } -Descending)

$payload = [pscustomobject]@{
    generated = ($now.ToString('yyyy-MM-dd HH:mm:ss'))
    now = (Get-Iso $now)
    localAgent = $LocalAgent
    agents = $agentList
    chats = $chatList
}
$json = ConvertTo-Json -InputObject $payload -Depth 6
# Generated output lives in <root>\dashboard\ (kept out of the project root;
# both files move together - the shell references the data file relatively).
$dashDir = Join-Path $Root 'dashboard'
if (-not (Test-Path -LiteralPath $dashDir)) { New-Item -ItemType Directory -Path $dashDir -Force | Out-Null }
Write-DashFile -Path (Join-Path $dashDir 'dashboard-data.js') -Content ('window.DASHBOARD_DATA = ' + $json + ';')
# Tiny poll stamp for the shell's probe-first poller: the panel loads this
# one-liner every 2s and only pulls the full payload when the stamp moved.
Write-DashFile -Path (Join-Path $dashDir 'dashboard-seq.js') -Content ('window.DASHBOARD_SEQ = "' + (Get-Date).Ticks + '"; window.DASHBOARD_HEARTBEAT = "' + (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") + '";')
if ($fp.Length -gt 0) { [System.IO.File]::WriteAllText($fpFile, $fp, $script:UTF8Bom) }   # remember what this output was built from

$tplPath = Join-Path $script:DirTemplates 'dashboard-template.html'
if (-not (Test-Path -LiteralPath $tplPath)) { if (-not $Quiet) { Write-Warning 'dashboard template missing' }; exit 0 }
$html = Read-TextFile -Path $tplPath
Write-DashFile -Path (Join-Path $dashDir 'dashboard.html') -Content $html
if (-not $Quiet) { Write-Host ('dashboard updated: ' + (Join-Path $dashDir 'dashboard.html')) }
