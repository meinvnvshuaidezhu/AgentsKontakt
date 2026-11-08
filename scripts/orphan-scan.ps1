param(
  [switch]$MoveToTrash,   # sweep the three trash classes into post\trash\ (default: read-only report)
  [switch]$Purge,         # delete expired trash items only
  [switch]$Empty,         # delete ALL trash items (-Yes required, else list only)
  [switch]$Yes,           # confirm -Empty
  [string]$Restore = '',  # trash_id -> move item back to its original path
  [int]$MinAgeHours = 24, # age gate for bad-name-mail / orphan-sidecar
  [string]$Root = ''
)
$ErrorActionPreference = 'Continue'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# orphan-scan.ps1 (v3, workbuddy spec n5w8): orphan-mail recycle station.
#
# Actions (enum - the trash branch only ever accepts 'trash'):
#   trash  - three classes MAY be collected: cold-quarantine, bad-name-mail,
#            orphan-sidecar (each with its own age safety valve)
#   report - five classes MUST NOT be moved: thread-no-status, thread-no-files,
#            chain-entry-missing, thread-file-unlisted, half-archived (moving
#            them would destroy evidence or an in-flight topic)
# First principle (n5w8): an orphan is EVIDENCE, not garbage - it goes into a
# visible container (post\trash\) for trash_retention_days, never straight to
# deletion. Four-source trace decides recoverable/ambiguous/unverifiable;
# unverifiable items are collected but NEVER auto-restored.

$script:DirTrash    = Join-Path $script:DirPost 'trash'
$script:TrashIndex  = Join-Path $script:DirTrash 'index.json'
$script:LastScan    = Join-Path $script:DirTrash '.lastscan'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-TrashConfig {
    $cfg = Get-SystemConfig
    $interval = 60; if ([string]$cfg['orphan_scan_interval_minutes'] -match '^\d+$') { $interval = [int]$cfg['orphan_scan_interval_minutes'] }
    $retention = 7;  if ([string]$cfg['trash_retention_days'] -match '^\d+$') { $retention = [int]$cfg['trash_retention_days'] }
    return @{ interval = $interval; retention = $retention }
}

$script:JournalCache = @{}
function Get-JournalHits {
    # Four-source trace helper: does ANY journal line contain this needle?
    # Per-file in-process cache - one scan reads each journal file once
    # (a journal can be tens of MB and is queried dozens of times per pass).
    param([string]$Needle)
    if (-not (Test-Path -LiteralPath $script:DirLogs)) { return $false }
    try {
        foreach ($jd in (Get-ChildItem -LiteralPath $script:DirLogs -Directory -ErrorAction SilentlyContinue)) {
            foreach ($jf in (Get-ChildItem -LiteralPath $jd.FullName -File -Filter 'journal*.log' -ErrorAction SilentlyContinue)) {
                if (-not $script:JournalCache.ContainsKey($jf.FullName)) {
                    try { $script:JournalCache[$jf.FullName] = [System.IO.File]::ReadAllText($jf.FullName) } catch { $script:JournalCache[$jf.FullName] = '' }
                }
                if ($script:JournalCache[$jf.FullName].Contains($Needle)) { return $true }
            }
        }
    } catch {}
    return $false
}

function Test-FourSourceTrace {
    # Where did this id come from? (n5w8: zero hits on all four = unverifiable)
    param([string]$Id, [string]$Topic, [string]$From, [string]$To)
    $hits = @{ sent = $false; peer_inbox = $false; journal = $false; status_json = $false }
    $stPath = Join-Path (Get-ThreadDir -Topic $Topic) 'status.json'
    if ($Topic -and (Test-Path -LiteralPath $stPath)) { $hits.status_json = $true }
    if ($Id) {
        foreach ($a in @($From, $To) | Where-Object { $_ }) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:DirMailboxes $a) 'sent') ($Id + '.md'))) { $hits.sent = $true }
            foreach ($b in @($From, $To) | Where-Object { $_ }) {
                if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:DirMailboxes $b) 'inbox') ($Id + '.md'))) { $hits.peer_inbox = $true }
            }
        }
        if (Get-JournalHits -Needle $Id) { $hits.journal = $true }
    }
    if ($Topic -and (Get-JournalHits -Needle $Topic)) { $hits.journal = $true }
    $count = @($hits.Values | Where-Object { $_ }).Count
    $verdict = 'unverifiable'
    if ($count -ge 2) { $verdict = 'recoverable' } elseif ($count -eq 1) { $verdict = 'ambiguous' }
    return @{ hits = $hits; count = $count; verdict = $verdict }
}

function Findings {
    # Accumulator for one scan pass.
    $script:Findings = New-Object System.Collections.Generic.List[object]
}
Findings

function Add-Finding {
    param([string]$Action, [string]$Kind, [string]$Path, [string]$Why,
          [string]$Id = '', [string]$Topic = '', [string]$From = '', [string]$To = '',
          [hashtable]$Trace = $null, [string]$Verdict = '')
    $script:Findings.Add([pscustomobject]@{
        action = $Action; kind = $Kind; path = $Path; why = $Why
        id = $Id; topic = $Topic; from = $From; to = $To
        trace = $Trace; verdict = $Verdict
    })
}

function Find-Orphans {
    # One read-only pass. Populates $script:Findings. Returns findings count.
    $now = Get-Date
    $minAge = $now.AddHours(-$MinAgeHours)

    # ---- trash class 1: cold-quarantine (everything in post\cold, mtime > 1min) ----
    $coldDir = Join-Path $script:DirPost 'cold'
    if (Test-Path -LiteralPath $coldDir) {
        foreach ($f in [System.IO.Directory]::GetFiles($coldDir)) {
            $fi = New-Object System.IO.FileInfo($f)
            if ($fi.LastWriteTime -gt $now.AddMinutes(-1)) { continue }   # safety valve: still being written
            Add-Finding -Action 'trash' -Kind 'cold-quarantine' -Path $f -Why 'quarantined by the anti-overwrite gate; only read path is this scan'
        }
    }

    # ---- trash class 2: bad-name-mail + class 3: orphan-sidecar ----
    # (.md name check via GetExtension - GetFiles($d,'*.md') misses 'X.md' on
    # some Windows builds; n5w8 implementation pit #1)
    foreach ($a in ((Get-RegisteredAgents | ForEach-Object { $_.name }))) {
        foreach ($zone in @('inbox', 'processing', 'sent')) {
            $d = Join-Path (Join-Path $script:DirMailboxes $a) $zone
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $all = @()
            try { $all = [System.IO.Directory]::GetFiles($d) } catch { continue }
            $mdNames = @{}
            foreach ($f in $all) {
                if ([System.IO.Path]::GetExtension($f) -eq '.md') { $mdNames[[System.IO.Path]::GetFileName($f).ToLower()] = $true }
            }
            foreach ($f in $all) {
                $fi = New-Object System.IO.FileInfo($f)
                $ext = [System.IO.Path]::GetExtension($f)
                $name = [System.IO.Path]::GetFileName($f)
                if ($ext -eq '.md') {
                    $isKnown = ($name -like 'msg-*') -or ($name -like 'sys-*') -or ($name -like '*.chain.md')
                    if (-not $isKnown -and $fi.LastWriteTime -lt $minAge) {
                        $fm = Read-FrontMatter -Path $f
                        $tr = Test-FourSourceTrace -Id ([string]$fm['id']) -Topic ([string]$fm['topic']) -From ([string]$fm['from']) -To ([string]$fm['to'])
                        Add-Finding -Action 'trash' -Kind 'bad-name-mail' -Path $f -Why ('.md letter whose name is not msg-*/sys-*/chain (unrecognized by every reader)') `
                            -Id ([string]$fm['id']) -Topic ([string]$fm['topic']) -From ([string]$fm['from']) -To ([string]$fm['to']) -Trace $tr.hits -Verdict $tr.verdict
                    }
                }
                elseif (($ext -eq '.status' -or $ext -eq '.progress') -and $fi.LastWriteTime -lt $minAge) {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f)
                    $hasLetter = $mdNames.ContainsKey(($stem + '.md').ToLower())
                    if (-not $hasLetter) {
                        Add-Finding -Action 'trash' -Kind 'orphan-sidecar' -Path $f -Why ('sidecar without its letter (' + $ext + ' orphan)')
                    }
                }
            }
        }
    }

    # ---- report classes (NEVER moved - n5w8 red line A5) ----
    $threadsRoot = Join-Path $script:DirPost 'threads'
    if (Test-Path -LiteralPath $threadsRoot) {
        foreach ($td in (Get-ChildItem -LiteralPath $threadsRoot -Directory -ErrorAction SilentlyContinue)) {
            $t = $td.Name
            $sp = Join-Path $td.FullName 'status.json'
            $chainFiles = @(Get-ChildItem -LiteralPath $td.FullName -File -Filter 'thread-*.md' -ErrorAction SilentlyContinue)
            if (-not (Test-Path -LiteralPath $sp)) {
                Add-Finding -Action 'report' -Kind 'thread-no-status' -Path $td.FullName -Why 'in-flight topic may live here - moving would destroy it'
                continue
            }
            if (-not $chainFiles.Count) {
                Add-Finding -Action 'report' -Kind 'thread-no-files' -Path $td.FullName -Why 'body already lost - moving the dir is destroying evidence'
                continue
            }
            try { $stj = [System.IO.File]::ReadAllText($sp) | ConvertFrom-Json } catch { continue }
            $listed = @([string]$stj.chain)
            foreach ($c in $listed) {
                if ($c -and -not (Test-Path -LiteralPath (Join-Path $td.FullName $c))) {
                    Add-Finding -Action 'report' -Kind 'chain-entry-missing' -Path (Join-Path $td.FullName $c) -Why 'chain lists it, disk does not - fix by restoring the file, not by moving'
                }
            }
            foreach ($cf in $chainFiles) {
                if ($listed -notcontains $cf.Name) {
                    Add-Finding -Action 'report' -Kind 'thread-file-unlisted' -Path $cf.FullName -Why 'correct disposition is adding it to the chain list, not moving'
                }
            }
        }
    }
    # half-archived: archive dir exists but JSONL lacks the topic
    $jsonl = Get-ArchiveJsonlPath
    $jsonlTopics = @{}
    if (Test-Path -LiteralPath $jsonl) {
        foreach ($ln in [System.IO.File]::ReadAllLines($jsonl)) {
            if (-not $ln.Trim()) { continue }
            try { $jsonlTopics[[string]($ln | ConvertFrom-Json).topic] = $true } catch {}
        }
    }
    foreach ($sm in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Filter 'summary.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-FrontMatter -Path $sm.FullName
        $tp = [string]$fm['topic']; if (-not $tp) { $tp = (Split-Path (Split-Path $sm.FullName -Parent) -Leaf) }
        if (-not $jsonlTopics.ContainsKey($tp)) {
            Add-Finding -Action 'report' -Kind 'half-archived' -Path (Split-Path $sm.FullName -Parent) -Why 'archive exists but JSONL lacks the topic - disposition is backfilling the index (ops\backfill-archive-index.ps1), not moving'
        }
    }
    return $script:Findings.Count
}

function Move-FindingToTrash {
    # n5w8 R2 write order: dir -> meta.json -> move file (rollback on failure:
    # file back to origin, dir removed). meta.json is the UI data source.
    param($Finding)
    $cfg = Get-TrashConfig
    $src = [string]$Finding.path
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $fi = New-Object System.IO.FileInfo($src)
    $trashId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (-join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ }))
    $dir = Join-Path $script:DirTrash $trashId
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $fm = Read-FrontMatter -Path $src
        $detected = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $traceObj = if ($Finding.trace) { $Finding.trace } else { @{} }
        $meta = [pscustomobject]@{
            trash_id = $trashId; kind = [string]$Finding.kind
            original_name = $fi.Name; original_path = $src
            item = 'item' + $fi.Extension; bytes = $fi.Length; mtime = $fi.LastWriteTime.ToString('o')
            detected_at = $detected; detected_by = 'orphan-scan'
            expires_at = (Get-Date).AddDays($cfg.retention).ToString('yyyy-MM-ddTHH:mm:sszzz')
            id = [string]$Finding.id; topic = [string]$Finding.topic
            from = [string]$Finding.from; to = [string]$Finding.to
            subject = [string]$fm['subject']; created = [string]$fm['created']
            excerpt = ((Read-TextFile -Path $src) -replace '\s+', ' ')
            reason = [string]$Finding.why; detail = ('detected by rule: ' + [string]$Finding.kind)
            trace = $traceObj; trace_hits = @($traceObj.Values | Where-Object { $_ }).Count
            recoverable = [bool]($Finding.verdict -eq 'recoverable')
            verdict = [string]$Finding.verdict; restored_at = ''
        }
        if ($meta.excerpt.Length -gt 4000) { $meta.excerpt = $meta.excerpt.Substring(0, 4000) }
        [System.IO.File]::WriteAllText((Join-Path $dir 'meta.json'), ($meta | ConvertTo-Json -Depth 8), $utf8NoBom)
        # move the item (+ sidecar if present) LAST - a crash before this point
        # leaves an empty dir that the next scan sweeps (A10)
        $dest = Join-Path $dir ('item' + $fi.Extension)
        Move-AtomicTo -File $src -DestPath $dest | Out-Null
        foreach ($se in @('.status', '.progress')) {
            $sideSrc = [System.IO.Path]::ChangeExtension($src, $se)
            if (Test-Path -LiteralPath $sideSrc) {
                Move-AtomicTo -File $sideSrc -DestPath (Join-Path $dir ('item' + $se)) | Out-Null
            }
        }
        Write-Journal -Agent 'postmaster' -Action 'TRASHED' -Detail ("$trashId | " + [string]$Finding.kind + ' | ' + $src + ' | id=' + [string]$Finding.id + ' | topic=' + [string]$Finding.topic)
        return $trashId
    } catch {
        # rollback: file back to origin, dir removed (n5w8 R2 write order)
        try {
            $itemPath = Join-Path $dir ('item' + $fi.Extension)
            if ((Test-Path -LiteralPath $itemPath) -and -not (Test-Path -LiteralPath $src)) {
                Move-AtomicTo -File $itemPath -DestPath $src | Out-Null
            }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
        Write-SystemLog ('orphan-scan: trash move FAILED and rolled back: ' + $src)
        return $null
    }
}

function Update-TrashIndex {
    # post\trash\index.json (no-BOM, same contract as index.jsonl) - rebuilt
    # from meta.json files on every mutation.
    $items = @()
    foreach ($d in (Get-ChildItem -LiteralPath $script:DirTrash -Directory -ErrorAction SilentlyContinue)) {
        $m = Join-Path $d.FullName 'meta.json'
        if (Test-Path -LiteralPath $m) {
            try { $items += ([System.IO.File]::ReadAllText($m) | ConvertFrom-Json) } catch {}
        }
    }
    $idx = [pscustomobject]@{
        generated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        retention_days = (Get-TrashConfig).retention
        count = $items.Count
        recoverable = @($items | Where-Object { $_.verdict -eq 'recoverable' }).Count
        items = $items
    }
    [System.IO.File]::WriteAllText($script:TrashIndex, ($idx | ConvertTo-Json -Depth 8), $utf8NoBom)
}

function Invoke-TrashPurge {
    # Delete expired items only. Every deletion leaves a PURGE journal line
    # carrying trash_id | kind | original_path | id | topic (n5w8 R3).
    $now = Get-Date
    $purged = 0
    foreach ($d in (Get-ChildItem -LiteralPath $script:DirTrash -Directory -ErrorAction SilentlyContinue)) {
        $m = Join-Path $d.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $m)) {
            # A10: empty dir (crashed write) -> swept, not counted
            $left = @(Get-ChildItem -LiteralPath $d.FullName -ErrorAction SilentlyContinue)
            if (-not $left.Count) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue }
            continue
        }
        try { $meta = [System.IO.File]::ReadAllText($m) | ConvertFrom-Json } catch { continue }
        $exp = $null
        try { $exp = [datetime]::Parse([string]$meta.expires_at) } catch {}
        if ($exp -and $exp -lt $now) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Journal -Agent 'postmaster' -Action 'PURGE' -Detail ("$([string]$meta.trash_id) | " + [string]$meta.kind + ' | ' + [string]$meta.original_path + ' | id=' + [string]$meta.id + ' | topic=' + [string]$meta.topic)
            $purged++
        }
    }
    if ($purged -gt 0) { Update-TrashIndex }
    return $purged
}

# ---------------------------------------------------------------- entry points

if ($Restore) {
    $srcDir = Join-Path $script:DirTrash $Restore
    $m = Join-Path $srcDir 'meta.json'
    if (-not (Test-Path -LiteralPath $m)) { Write-Error ('restore: no such trash_id: ' + $Restore); exit 1 }
    $meta = [System.IO.File]::ReadAllText($m) | ConvertFrom-Json
    $orig = [string]$meta.original_path
    if (Test-Path -LiteralPath $orig) {
        Write-Error ('restore: original path already exists, refusing: ' + $orig); exit 1
    }
    $item = Join-Path $srcDir ([string]$meta.item)
    if (-not (Test-Path -LiteralPath $item)) { Write-Error ('restore: item file missing in trash dir'); exit 1 }
    $odir = Split-Path $orig -Parent
    if (-not (Test-Path -LiteralPath $odir)) { New-Item -ItemType Directory -Path $odir -Force | Out-Null }
    Move-AtomicTo -File $item -DestPath $orig | Out-Null
    foreach ($se in @('.status', '.progress')) {
        $side = Join-Path $srcDir ('item' + $se)
        if (Test-Path -LiteralPath $side) { Move-AtomicTo -File $side -DestPath ([System.IO.Path]::ChangeExtension($orig, $se)) | Out-Null }
    }
    # restored_at into meta (kept in the trash dir for audit, minus the item)
    $meta | Add-Member -NotePropertyName restored_at -NotePropertyValue ((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')) -Force
    [System.IO.File]::WriteAllText($m, ($meta | ConvertTo-Json -Depth 8), $utf8NoBom)
    Update-TrashIndex
    Write-Host ('RESTORED {0} -> {1}' -f $Restore, $orig)
    exit 0
}

if ($Empty) {
    if (-not $Yes) {
        Write-Host 'EMPTY: list only (add -Yes to actually delete):'
        foreach ($d in (Get-ChildItem -LiteralPath $script:DirTrash -Directory -ErrorAction SilentlyContinue)) {
            $m = Join-Path $d.FullName 'meta.json'
            if (Test-Path -LiteralPath $m) {
                $meta = [System.IO.File]::ReadAllText($m) | ConvertFrom-Json
                Write-Host ('  ' + [string]$meta.trash_id + ' | ' + [string]$meta.kind + ' | ' + [string]$meta.original_name + ' | ' + [string]$meta.verdict)
            }
        }
        exit 0
    }
    $n = 0
    foreach ($d in (Get-ChildItem -LiteralPath $script:DirTrash -Directory -ErrorAction SilentlyContinue)) {
        $m = Join-Path $d.FullName 'meta.json'
        if (Test-Path -LiteralPath $m) {
            $meta = [System.IO.File]::ReadAllText($m) | ConvertFrom-Json
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Journal -Agent 'postmaster' -Action 'PURGE' -Detail ("$([string]$meta.trash_id) | " + [string]$meta.kind + ' | ' + [string]$meta.original_path + ' | id=' + [string]$meta.id + ' | topic=' + [string]$meta.topic)
            $n++
        }
    }
    Update-TrashIndex
    Write-Host ('EMPTIED: ' + $n + ' item(s) removed')
    exit 0
}

if ($Purge) {
    $n = Invoke-TrashPurge
    Write-Host ('PURGED: ' + $n + ' expired item(s)')
    exit 0
}

# ---- scan (default read-only report; -MoveToTrash collects the trash class) ----
$count = Find-Orphans
$trashN = 0; $reportN = 0
foreach ($f in $script:Findings) {
    if ($f.action -eq 'trash') {
        $trashN++
        $traceTxt = ''
        if ($f.trace) { $traceTxt = (' trace[' + ((@($f.trace.Keys | Where-Object { $f.trace[$_] }) -join ',')) + '] verdict=' + $f.verdict) }
        Write-Host ('TRASH    {0}  {1}  why={2}{3}' -f $f.kind, $f.path, $f.why, $traceTxt)
        if ($MoveToTrash) {
            $tid = Move-FindingToTrash -Finding $f
            if ($tid) { Write-Host ('         -> binned as ' + $tid) }
        }
    } else {
        $reportN++
        Write-Host ('REPORT   {0}  {1}  why={2}' -f $f.kind, $f.path, $f.why)
    }
}
if ($MoveToTrash) {
    Update-TrashIndex
    # stamp the throttle gate HERE (not in cleanup.ps1): the scan that actually
    # ran owns the stamp - no cross-process timing races (A11)
    [System.IO.File]::WriteAllText($script:LastScan, (Get-Date).ToString('o'), $utf8NoBom)
}
Write-Host ('orphan scan: {0} finding(s) - trash {1}, report {2}{3}' -f $count, $trashN, $reportN, $(if ($MoveToTrash) { ' [collected]' } else { ' [report only]' }))
exit 0
