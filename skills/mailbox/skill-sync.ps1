# skill-sync.ps1 - SKILL entry-shell freshness self-check (owner request, 2026-11-09).
#
# The deployed SKILL.md copy (the one agents actually load, sitting next to
# this script) can lag behind the data-root copy after an application update.
# One call compares hashes and self-heals, so staleness survives at most one
# invocation.
#
# All paths are DISCOVERED, never hardcoded (install location and user name
# vary per machine):
#   target = SKILL.md next to THIS script (the deployed copy; $PSScriptRoot)
#   data root, in the same resolution spirit as every post-office script:
#     1. $env:MAILBOX_ROOT
#     2. pointer file <this skill folder>\.mailbox-root - one line, the data
#        root path, written by install.ps1 at S3a (never shipped in the zip)
#     3. self-detection: this folder directly under a <X>\skills\ whose <X>
#        holds registry\  ->  <X> is the data root
#   anchor = <data root>\skills\mailbox\SKILL.md  (the distribution copy -
#            refreshed by every install, and synced by whoever edits the master)
#
# Update rule (docs\Agent操作指引.md §6): edit the master only, publish to the
# data root, let agents self-heal from it - hand-editing a deployed copy is
# what the heal undoes.
# Exit 0 = fresh (or healed); 1 = data root or anchor not found.
#
# Scripts stay ASCII on purpose (PS 5.1 no-BOM GBK trap) - same rule as core.

param()
$ErrorActionPreference = 'Stop'

$target = Join-Path $PSScriptRoot 'SKILL.md'

$root = ''
if ($env:MAILBOX_ROOT) { $root = $env:MAILBOX_ROOT.Trim() }

if (-not $root) {
    $ptr = Join-Path $PSScriptRoot '.mailbox-root'
    if (Test-Path -LiteralPath $ptr) {
        try { $root = ([System.IO.File]::ReadAllText($ptr)).Trim() } catch { $root = '' }
    }
}

if (-not $root) {
    $p1 = Split-Path $PSScriptRoot -Parent               # ...\skills
    if ($p1 -and (Split-Path $p1 -Leaf) -eq 'skills') {
        $cand = Split-Path $p1 -Parent                   # the data-root candidate
        if ($cand -and (Test-Path -LiteralPath (Join-Path $cand 'registry'))) { $root = $cand }
    }
}

if (-not $root -or -not (Test-Path -LiteralPath $root)) {
    Write-Host 'SKIP: data root unknown - set $env:MAILBOX_ROOT, or write <skill folder>\.mailbox-root (one line: the data root path)'
    exit 1
}

$anchor = Join-Path (Join-Path $root 'skills\mailbox') 'SKILL.md'
if (-not (Test-Path -LiteralPath $anchor)) {
    Write-Host ('SKIP: no SKILL.md in the data root (' + $anchor + ') - reinstall, or publish the master copy there first')
    exit 1
}

if (-not (Test-Path -LiteralPath $target)) {
    Copy-Item -LiteralPath $anchor -Destination $target -Force
    Write-Host ('HEALED: deployed SKILL.md missing - copied from ' + $anchor)
    exit 0
}

$hT = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$hA = (Get-FileHash -LiteralPath $anchor -Algorithm SHA256).Hash
if ($hT -eq $hA) {
    Write-Host ('FRESH: deployed copy matches ' + $anchor)
    exit 0
}

Copy-Item -LiteralPath $anchor -Destination $target -Force
Write-Host ('HEALED: deployed copy was stale - synced from ' + $anchor)
Write-Host 'NOTE: the copy already loaded into this session stays as-is; keep following the on-disk guide (skill rule 0). The fresh shell loads on the next invocation.'
exit 0
