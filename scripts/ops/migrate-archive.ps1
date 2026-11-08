param([string]$Root = '')
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
. (Join-Path $PSScriptRoot '..\core\common.ps1')

# One-off migration: archive\<month>\<topic>\ -> archive\<from>\<yyyy>\<MM>\<dd>\<topic>\
# - merges topics that were split across month folders into one destination
# - rewrites stale path references inside the moved .md files
# - backfills summary front-matter (participants, models, date, title)
# - rebuilds archive\index.md and per-agent _index.md
# Safe to re-run: topics already in the new layout are skipped.

if (-not (Test-Path -LiteralPath $script:DirArchive)) { Write-Host 'no archive dir; nothing to migrate'; exit 0 }

# topic id -> source dirs (old month layout only)
$topicDirs = @{}
foreach ($d in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name -notmatch '^t-[0-9]{8}-[A-Za-z0-9]+$') { continue }
    $parent = Split-Path $d.FullName -Parent
    $month = Split-Path $parent -Leaf
    if ($month -notmatch '^\d{4}-\d{2}$') { continue }  # already in new layout
    $tp = $d.Name
    if (-not $topicDirs.ContainsKey($tp)) { $topicDirs[$tp] = @() }
    $topicDirs[$tp] += $d.FullName
}

if (-not $topicDirs.Count) { Write-Host 'nothing to migrate (all topics already in new layout)' }

$migrated = 0
foreach ($tp in ($topicDirs.Keys | Sort-Object)) {
    $srcDirs = @($topicDirs[$tp])

    # initiator: existing summary front-matter first, then any request message
    $from = ''; $to = ''; $closed = ''
    foreach ($sd in $srcDirs) {
        $sp = Join-Path $sd 'summary.md'
        if (Test-Path -LiteralPath $sp) {
            $sfm = Read-FrontMatter -Path $sp
            $from = [string]$sfm['from']; $to = [string]$sfm['to']; $closed = [string]$sfm['closed']
            break
        }
    }
    foreach ($sd in $srcDirs) {
        if ($from -and $to) { break }
        foreach ($f in (Get-ChildItem -LiteralPath $sd -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq 'summary.md') { continue }
            $m = Read-FrontMatter -Path $f.FullName
            if (([string]$m['topic'] -eq $tp) -and ([string]$m['type'] -eq 'request')) {
                if (-not $from) { $from = [string]$m['from'] }
                if (-not $to) { $to = [string]$m['to'] }
                break
            }
        }
    }
    if (-not $from) { Write-Host ('SKIP ' + $tp + ': initiator unknown'); continue }
    if (-not $to) { $to = 'unknown' }

    $destDir = Get-TopicArchiveDir -FromAgent $from -Topic $tp -FallbackDate ([datetime]::MinValue)
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    # remember old path prefixes (both separators) for body rewriting
    $oldPrefixes = @()
    foreach ($sd in $srcDirs) {
        $month = Split-Path (Split-Path $sd -Parent) -Leaf
        $oldPrefixes += ('archive\' + $month + '\' + $tp)
        $oldPrefixes += ('archive/' + $month + '/' + $tp)
    }
    $relNewBs = $destDir.Substring($script:DirArchive.Length + 1).Replace('/', '\')

    # move every file of every source dir into the destination
    foreach ($sd in $srcDirs) {
        foreach ($f in (Get-ChildItem -LiteralPath $sd -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($f.DirectoryName -ne $sd) { continue }  # topic dirs are flat
            Move-AtomicUnique -File $f.FullName -DestDir $destDir | Out-Null
        }
        if (-not (Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            [System.IO.Directory]::Delete($sd, $false)
        }
    }

    # rewrite stale references inside the moved .md files
    foreach ($f in (Get-ChildItem -LiteralPath $destDir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        $orig = $text
        foreach ($op in $oldPrefixes) {
            $esc = [regex]::Escape($op)
            $text = [regex]::Replace($text, $esc, $relNewBs, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        if ($text -ne $orig) { [System.IO.File]::WriteAllText($f.FullName, $text, $script:UTF8Bom) }
    }

    # backfill summary front-matter
    $sp = Join-Path $destDir 'summary.md'
    if (Test-Path -LiteralPath $sp) {
        Merge-SummaryFrontMatter -Path $sp -Topic $tp -From $from -To $to -Closed $closed
    }

    # drop now-empty month dirs (e.g. 2026-09) left behind
    foreach ($sd in $srcDirs) {
        $monthDir = Split-Path $sd -Parent
        if ((Split-Path $monthDir -Leaf) -match '^\d{4}-\d{2}$' -and
            -not (Get-ChildItem -LiteralPath $monthDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            [System.IO.Directory]::Delete($monthDir, $false)
        }
    }

    $migrated++
    Write-Host ('MIGRATED ' + $tp + ' (' + $srcDirs.Count + ' source dir(s)) -> ' + $destDir)
}

Update-ArchiveIndexes
Update-Dashboard
Write-Host ('DONE: ' + $migrated + ' topic(s) migrated; indexes rebuilt.')
