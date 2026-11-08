# close.ps1 - stable entry stub (r4.1: forwards to archive.ps1, which splits
# v3 topics from legacy in-flight ones by the presence of status.json).
# The implementation lives in archive.ps1 (v3) and core\archive-legacy.ps1 (v2).
param(
  [Parameter(Mandatory=$true)][string]$Topic,
  [Parameter(Mandatory=$true)][string]$Agent,
  [string]$Summary = '',
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
& (Join-Path $PSScriptRoot 'archive.ps1') -Topic $Topic -Agent $Agent -Root $Root
exit $LASTEXITCODE
