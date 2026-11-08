param(
  [switch]$CheckOnly,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot '..\core\common.ps1')

# One-shot JSONL backfill (v3 §2.4, review C1): snapshot the archive BEFORE
# the JSONL backend switches on. Three sources are unioned, deduped by topic:
#   1. directory scan  - every archive\<...>\<topic>\summary.md (authoritative:
#                        thread_ref comes from the real path)
#   2. archive\index.md rows (may miss entries, may have dupes - never trusted
#      alone)
#   3. archive\<agent>\_index.md rows
# Existing JSONL lines are merged in (idempotent - the script may be re-run).
# Success criterion (review C1): the union-of-sources topic set == the
# post-backfill JSONL topic set. "Total counts match" is NOT the criterion -
# the three sources naturally disagree on counts.
# Runs under the same archive index lock as archive.ps1 (no double-write).

if (-not (Test-Path -LiteralPath $script:DirArchive)) { Write-Host 'backfill: no archive yet'; exit 0 }

$sources = @{ dir = @{}; index = @{}; peragent = @{} }

# --- source 1: directory scan (authoritative) ---
foreach ($f in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Filter 'summary.md' -File -ErrorAction SilentlyContinue)) {
    $fm = Read-FrontMatter -Path $f.FullName
    $tp = [string]$fm['topic']; if (-not $tp) { $tp = (Split-Path (Split-Path $f.FullName -Parent) -Leaf) }
    $rel = $f.FullName.Substring($script:DirArchive.Length + 1).Replace('\', '/')
    $threadRef = $rel.Substring(0, $rel.LastIndexOf('/'))
    $sources.dir[$tp] = @{
        topic = $tp; title = [string]$fm['title']; initiator = [string]$fm['from']
        responder = [string]$fm['to']; start_date = [string]$fm['date']
        closed_time = [string]$fm['closed']; thread_ref = $threadRef; participants = @()
    }
}

# --- source 2: index.md rows ---
$idxPath = Join-Path $script:DirArchive 'index.md'
if (Test-Path -LiteralPath $idxPath) {
    foreach ($ln in [System.IO.File]::ReadAllLines($idxPath)) {
        if ($ln -match '^\|\s*([^|]+)\|\s*\[?(t-[A-Za-z0-9\-]+)\]?\(([^)]+)\)\s*\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*$') {
            $tp = $Matches[2].Trim()
            if (-not $sources.index.ContainsKey($tp)) {
                $sources.index[$tp] = @{ topic = $tp; title = $Matches[4].Trim(); date = $Matches[1].Trim() }
            }
        }
    }
}

# --- source 3: per-agent _index.md rows ---
foreach ($f in (Get-ChildItem -LiteralPath $script:DirArchive -File -Filter '_index.md' -ErrorAction SilentlyContinue)) {
    foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName)) {
        if ($ln -match '^\|\s*([^|]+)\|\s*\[?(t-[A-Za-z0-9\-]+)\]?\(([^)]+)\)') {
            $tp = $Matches[2].Trim()
            if (-not $sources.peragent.ContainsKey($tp)) { $sources.peragent[$tp] = @{ topic = $tp } }
        }
    }
}

$union = @{}
foreach ($k in $sources.dir.Keys)     { $union[$k] = $true }
foreach ($k in $sources.index.Keys)   { $union[$k] = $true }
foreach ($k in $sources.peragent.Keys){ $union[$k] = $true }
Write-Host ('backfill: sources - dir scan {0}, index.md {1}, _index.md {2}; union {3} topics' -f `
    $sources.dir.Count, $sources.index.Count, $sources.peragent.Count, $union.Count)

if ($CheckOnly) {
    $have = @{}
    $jp = Get-ArchiveJsonlPath
    if (Test-Path -LiteralPath $jp) {
        foreach ($ln in [System.IO.File]::ReadAllLines($jp)) {
            if (-not $ln.Trim()) { continue }
            try { $have[[string]($ln | ConvertFrom-Json).topic] = $true } catch {}
        }
    }
    $missing = @($union.Keys | Where-Object { -not $have.ContainsKey($_) })
    $extra   = @($have.Keys   | Where-Object { -not $union.ContainsKey($_) })
    Write-Host ('backfill check: jsonl has {0} topics; missing from jsonl: {1}; not in sources: {2}' -f $have.Count, $missing.Count, $extra.Count)
    if ($missing.Count) { $missing | ForEach-Object { Write-Host ('  missing: ' + $_) } }
    if ($extra.Count)   { $extra   | ForEach-Object { Write-Host ('  extra:   ' + $_) } }
    exit 0
}

# --- backfill under the archive index lock (idempotent) ---
$lock = Get-ArchiveIndexLock
if (-not $lock) { Write-Error 'backfill: archive index lock busy'; exit 1 }
try {
    $path = Get-ArchiveJsonlPath
    $existing = @{}
    $keepLines = @()
    if (Test-Path -LiteralPath $path) {
        foreach ($ln in [System.IO.File]::ReadAllLines($path)) {
            if (-not $ln.Trim()) { continue }
            try {
                $o = $ln | ConvertFrom-Json
                $existing[[string]$o.topic] = $ln
                $keepLines += $ln
            } catch { $keepLines += $ln }   # line-tolerant: bad lines ride along
        }
    }
    $added = 0
    foreach ($tp in ($union.Keys | Sort-Object)) {
        if ($existing.ContainsKey($tp)) { continue }   # idempotent
        $rec = $sources.dir[$tp]
        if (-not $rec) { $rec = $sources.index[$tp] }   # index-only entry (title/date best effort)
        if (-not $rec) { $rec = @{ topic = $tp; title = ''; initiator = ''; responder = ''; start_date = ''; closed_time = ''; thread_ref = '' } }
        $lineObj = @{
            topic = $tp; title = [string]$rec.title; initiator = [string]$rec.initiator
            responder = [string]$rec.responder; start_date = [string]$rec.start_date
            closed_time = [string]$rec.closed_time; thread_ref = [string]$rec.thread_ref; participants = @()
        }
        $keepLines += ($lineObj | ConvertTo-Json -Compress -Depth 6)
        $added++
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($path, $keepLines, $utf8NoBom)
    Write-Host ('backfill: wrote {0} topics to index.jsonl (+{1} new)' -f $keepLines.Count, $added)
} finally { Release-TopicLock -Lock $lock }

# --- criterion check: union set == jsonl set ---
$have2 = @{}
foreach ($ln in [System.IO.File]::ReadAllLines((Get-ArchiveJsonlPath))) {
    if (-not $ln.Trim()) { continue }
    try { $have2[[string]($ln | ConvertFrom-Json).topic] = $true } catch {}
}
$okSet = $true
foreach ($t in $union.Keys) { if (-not $have2.ContainsKey($t)) { $okSet = $false; Write-Host ('  FAIL: still missing ' + $t) } }
foreach ($t in $have2.Keys) { if (-not $union.ContainsKey($t)) { $okSet = $false; Write-Host ('  FAIL: extra ' + $t) } }
if ($okSet) { Write-Host ('backfill criterion MET: union ({0}) == jsonl ({1})' -f $union.Count, $have2.Count); exit 0 }
Write-Host 'backfill criterion FAILED'; exit 1
