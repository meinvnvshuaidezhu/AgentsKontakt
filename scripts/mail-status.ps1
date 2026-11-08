param(
  [string]$Id = '',
  [string]$Topic = '',
  [string]$Agent = '',
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# Stage of a message or topic, for honest progress reporting. The directory
# IS the state:  inbox = PENDING pickup, processing = WORKING (the <id>.progress
# sidecar holds the handler's latest note), archive = CLOSED/replied.
# Usage: mail-status -Id <msg-id> | -Topic <t-...> | -Agent <name>

if (-not ($Id -or $Topic -or $Agent)) { Write-Error (Get-AkText 'mailstatus.usage' 'usage: mail-status -Id <msg-id> | -Topic <t-...> | -Agent <name>'); exit 1 }

$roots = @($script:DirMailboxes, $script:DirArchive)
$found = @()
foreach ($r in $roots) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $files = Get-ChildItem -LiteralPath $r -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if ($Agent -and ($f.FullName -notmatch ('\\' + [regex]::Escape($Agent) + '\\'))) { continue }
        if ($Id -and ($f.BaseName -ne $Id)) { continue }
        if ($Topic) {
            $fmq = Read-FrontMatter -Path $f.FullName
            if ([string]$fmq['topic'] -ne $Topic) { continue }
        }
        $found += $f
    }
}

if (-not $found.Count) { Write-Host (Get-AkText 'mailstatus.no-match' 'no matching message'); exit 0 }

foreach ($f in ($found | Sort-Object FullName)) {
    $stage = Get-AkText 'mailstatus.stage.archived' 'ARCHIVED(replied/closed)'
    if ($f.FullName -match '\\inbox\\') { $stage = Get-AkText 'mailstatus.stage.pending' 'PENDING(inbox, not picked up)' }
    elseif ($f.FullName -match '\\processing\\') { $stage = Get-AkText 'mailstatus.stage.working' 'WORKING(processing)' }
    elseif ($f.FullName -match '\\sent\\') { $stage = Get-AkText 'mailstatus.stage.inflight' 'IN-FLIGHT(sent, master)' }
    $fm = Read-FrontMatter -Path $f.FullName
    $note = ''
    $side = Join-Path $f.DirectoryName ($f.BaseName + '.progress')
    if (Test-Path -LiteralPath $side) {
        $last = Get-Content -LiteralPath $side -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue
        $age = [int]((New-TimeSpan (Get-Item -LiteralPath $side).LastWriteTime (Get-Date)).TotalMinutes)
        $note = Get-AkText 'mailstatus.heartbeat' ' | heartbeat({0}min ago): {1}' $age $last
    }
    if ($f.FullName -match '\\sent\\') {
        $mst = Get-MailStatus -MessagePath $f.FullName
        if ($mst.Count) {
            $reason = [string]$mst['reason']
            $note = ' | status=' + (Get-AkStatusName ([string]$mst['status'])) + $(if ($reason) { ' reason=' + $reason }) + ' updated=' + [string]$mst['updated'] + $note
        }
    }
    Write-Host ("{0} | {1} | topic={2} | {3}->{4} | type={5}{6}" -f $stage, $f.BaseName, $fm['topic'], $fm['from'], $fm['to'], $fm['type'], $note)
}
