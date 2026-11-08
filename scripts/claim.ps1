param(
  [Parameter(Mandatory=$true)][string]$File,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# v2 note: under the new post-office model, PUSH deliveries are claimed by the
# post office itself (route.ps1 claim-as-mutex) before the agent is woken.
# This script stays for PULL agents as an explicit "I started working" move;
# it may be retired once every agent is PUSH or daemon-driven.

if (-not (Test-Path -LiteralPath $File)) { Write-Host (Get-AkText 'claim.already-claimed' 'already claimed or gone'); exit 0 }
$File = (Get-Item -LiteralPath $File).FullName
$agent = Get-AgentFromPath -FilePath $File
if (-not $agent) { Write-Error (Get-AkText 'claim.err-not-inbox' 'file is not inside a registered inbox'); exit 1 }

$inboxDir = Split-Path $File -Parent
$procDir  = Join-Path (Split-Path $inboxDir -Parent) 'processing'
$dest = Move-Atomic -File $File -DestDir $procDir

# Carry a requeued dispatch sidecar along (same orphaning fix as route.ps1's
# claim): a letter that cycled before would leave inbox\<id>.progress behind.
$sideIn = Join-Path $inboxDir ([System.IO.Path]::GetFileNameWithoutExtension($File) + '.progress')
if (Test-Path -LiteralPath $sideIn) {
    try { Move-Atomic -File $sideIn -DestDir $procDir | Out-Null } catch {}
}

Update-RegistryField -Agent $agent -Key 'last_seen' -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') | Out-Null

$fm = Read-FrontMatter -Path $dest
$mid = [string]$fm['id']
if (-not $mid) { $mid = [System.IO.Path]::GetFileNameWithoutExtension($dest) }
Write-Journal -Agent $agent -Action 'CLAIM' -Detail ("{0} | topic={1}" -f $mid, $fm['topic'])
Write-Host (Get-AkText 'claim.claimed' 'CLAIMED {0} by {1}' $mid $agent)
