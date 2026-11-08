param(
  [string]$File = '',
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


# v2 note: under the new post-office model, PUSH deliveries are claimed by the
# post office itself (route.ps1 claim-as-mutex) before the agent is woken.
# This script stays for PULL agents as an explicit "I started working" move;
# it may be retired once every agent is PUSH or daemon-driven.

if (-not (Test-Path -LiteralPath $File)) { Write-Host (Get-AkText 'claim.already-claimed' 'already claimed or gone'); exit 0 }
$File = (Get-Item -LiteralPath $File).FullName
$agent = Get-AgentFromPath -FilePath $File
if (-not $agent) { Write-Error (Get-AkText 'claim.err-not-inbox' 'file is not inside a registered inbox'); exit 1 }

# v3 branch: a <topic>.chain.md copy is claimed in place - no physical move
# (overwrite-style view), the state machine flips pending -> processing and
# stamps last_heartbeat. Only the current recipient (status.to) may claim.
if ($File -match '\.chain\.md$') {
    $topic = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($File))
    $st = Get-TopicStatus -Topic $topic
    if (-not $st) { Write-Error ('claim: no v3 status for topic ' + $topic); exit 1 }
    if ([string]$st.to -ne $agent) {
        Write-Error ('claim: {0} is not the current recipient of {1} (to={2})' -f $agent, $topic, [string]$st.to); exit 1
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    if ([string]$st.state -notin @('pending', 'processing')) {
        Write-Error ('claim: topic {0} is {1} - nothing to claim (pending/processing only)' -f $topic, [string]$st.state); exit 1
    }
    $null = Set-TopicStatus -Topic $topic -Fields @{
        state = 'processing'; last_heartbeat = $stamp
        state_updated_by = $agent; state_updated_at = $stamp
    }
    Update-RegistryField -Agent $agent -Key 'last_seen' -Value $stamp | Out-Null
    Write-Journal -Agent $agent -Action 'CLAIM' -Detail ("{0} | v3 chain copy -> processing" -f $topic)
    Write-Host (Get-AkText 'claim.claimed' 'CLAIMED {0} by {1}' $topic $agent)
    exit 0
}

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
