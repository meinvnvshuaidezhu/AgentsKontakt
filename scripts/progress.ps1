param(
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Note,
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

# Accept a full path or a bare message id.
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
