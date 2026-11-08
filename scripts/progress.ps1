param(
  [string]$File = '',
  [string]$Note = '',
  [string]$Topic = '',
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# Progress heartbeat for a claimed (processing) message. The processing agent
# calls this at every milestone; the note lands in a <msgid>.progress sidecar
# next to the message (liveness signal for cleanup.ps1) and in the journal
# (feed.ps1 shows it, so the other side can tell "working" from "dead").

if (-not $File -and -not $Topic) { Write-Error (Get-AkText 'progress.usage' 'usage: progress.ps1 -File <msg path> -Note <text> | -Topic <t-...> -Note <text>'); exit 1 }

# v3 branch first: heartbeat refresh for a v3 topic (-Topic <t-...>, or -File
# pointing at a <topic>.chain.md copy). Only meaningful in the processing
# state; the timestamp lands in status.json.last_heartbeat (metadata liveness, §5).
if ($Topic -or ($File -match '\.chain\.md$')) {
    $t = if ($Topic) { $Topic } else { ([System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($File))) }
    $st = Get-TopicStatus -Topic $t
    if (-not $st) { Write-Error (Get-AkText 'progress.not-found' 'progress: no v3 topic: {0}' $t); exit 1 }
    if ([string]$st.state -ne 'processing') {
        Write-Error ('progress: topic {0} is {1} (heartbeat only meaningful while processing)' -f $t, [string]$st.state); exit 1
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $null = Set-TopicStatus -Topic $t -Fields @{ last_heartbeat = $stamp }
    $agentV3 = [string]$st.to
    Write-Journal -Agent $agentV3 -Action 'PROGRESS' -Detail ($t + ' | ' + $Note)
    Write-Host (Get-AkText 'progress.ok' 'PROGRESS {0}' $t)
    exit 0
}

# Accept a full path or a bare message id.
if (-not $File) { Write-Error (Get-AkText 'progress.usage' 'usage: progress.ps1 -File <msg path> -Note <text>'); exit 1 }
if (-not (Test-Path -LiteralPath $File)) {
    $hit = Get-ChildItem -LiteralPath $script:DirMailboxes -Recurse -File -Filter ($File + '.md') -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\processing\\' } | Select-Object -First 1
    if ($hit) { $File = $hit.FullName }
}
if (-not (Test-Path -LiteralPath $File)) { Write-Error (Get-AkText 'progress.not-found' 'progress: message not found: {0}' $File); exit 1 }
$File = (Get-Item -LiteralPath $File).FullName

$mbEsc = [regex]::Escape($script:DirMailboxes)
if ($File -notmatch ($mbEsc + '\\([^\\]+)\\processing\\')) {
    Write-Error (Get-AkText 'progress.not-processing' 'progress: message is not in a processing folder (claim it first)'); exit 1
}
$agent = $Matches[1]

$side = Join-Path (Split-Path $File -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($File) + '.progress')
$line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Note
[System.IO.File]::AppendAllText($side, $line + "`r`n", $script:UTF8Bom)

$mid = [System.IO.Path]::GetFileNameWithoutExtension($File)
Write-Journal -Agent $agent -Action 'PROGRESS' -Detail ($mid + ' | ' + $Note)
Write-Host (Get-AkText 'progress.ok' 'PROGRESS {0}' $mid)
