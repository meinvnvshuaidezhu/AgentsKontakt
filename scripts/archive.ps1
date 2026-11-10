param(
  [string]$Topic = '',
  [string]$Agent = '',
  [string]$Summary = '',
  [string]$Root = '',
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


# v3 archive entry (r4.1). Close-and-archive is split by topic kind:
#   - post\threads\<topic>\status.json exists  -> v3: move the neutral chain +
#     final status into the archive, write the JSONL record (both parties
#     queryable), regenerate the md human view, lockdown.
#   - no status.json                           -> legacy in-flight topic (v2
#     semantics): the original full-mailbox gather close runs unchanged
#     (core\archive-legacy.ps1, also reachable via close.ps1).
# The archive gate (initiator-only) lives inside each branch: v3 enforces it
# here, legacy enforces it in archive-legacy.ps1.

$statusPath = Get-StatusPath -Topic $Topic
if (Test-Path -LiteralPath $statusPath) {
    $st = Get-TopicStatus -Topic $Topic
    if (-not $st) { Write-Error ('archive: status.json unreadable for ' + $Topic); exit 1 }
    if ([string]$st.from -and $Agent -ne [string]$st.from) {
        # archive gate: only the initiator may archive a v3 topic (manual path;
        # the auto path runs as postmaster from cleanup.ps1)
        Write-Journal -Agent $Agent -Action 'DENIED' -Detail ('topic=' + $Topic + ' | closer=' + $Agent + ' | initiator=' + [string]$st.from)
        $body = (Get-AkLines 'close.denied.body' 'Archive request denied.' '' 'topic: {0}' 'closer: {1}' 'initiator: {2}' '' 'Only the topic initiator may close and archive a topic.' |
            ForEach-Object { $_ -f $Topic, $Agent, [string]$st.from }) -join "`r`n"
        $mail = Write-SystemMail -To $Agent -Topic $Topic -Subject ('ARCHIVE-DENIED ' + $Topic) -Body $body
        $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'core\route.ps1') -File $mail -Root $Root 2>&1
        Write-Host (Get-AkText 'close.denied' 'DENIED topic {0} (closer {1} is not the initiator {2})' $Topic $Agent [string]$st.from)
        exit 1
    }
    if ([string]$st.state -ne 'answered' -and [string]$st.state -ne 'archived') {
        Write-Error ('archive: topic {0} is {1} - only answered topics can be archived (send kind=archive-note as the initiator, or wait for auto-archive)' -f $Topic, [string]$st.state)
        exit 1
    }
    $dest = Invoke-TopicArchive -Topic $Topic -ClosedBy $Agent
    # both mailboxes cleared of the topic's copies (answering side already clean)
    foreach ($a in @([string]$st.from, [string]$st.to)) {
        if ($a) { $null = Clear-ThreadCopies -Topic $Topic -Agent $a }
    }
    $null = Write-SystemMail -To ([string]$st.from) -Topic $Topic -Subject ('ARCHIVED ' + $Topic) -Body ('Topic ' + $Topic + ' archived to ' + $dest + ' by ' + $Agent + '.')
    $null = Write-SystemMail -To ([string]$st.to) -Topic $Topic -Subject ('ARCHIVED ' + $Topic) -Body ('Topic ' + $Topic + ' archived to ' + $dest + ' by ' + $Agent + '.')
    Update-Dashboard
    Write-Host (Get-AkText 'close.closed.v3' 'CLOSED topic {0} -> {1}' $Topic $dest)
    Write-Host (Get-AkText 'close.summaryhint' 'Summary: {0} (read-only locked; attrib -r <file> to edit, attrib +r to relock)' (Join-Path $dest 'summary.md'))
    exit 0
}

# legacy branch: no v3 status.json -> original v2 full-mailbox gather close
& (Join-Path $PSScriptRoot 'core\archive-legacy.ps1') -Topic $Topic -Agent $Agent -Root $Root
exit $LASTEXITCODE
