param(
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

Initialize-Tree

$agents = Get-RegisteredAgents
$names = @()
foreach ($a in $agents) {
    if ([string]::IsNullOrWhiteSpace($a.name) -or [string]::IsNullOrWhiteSpace($a.inbox)) { continue }
    Ensure-AgentDirs -Name $a.name -InboxRel $a.inbox | Out-Null
    $names += $a.name
}

Write-Host (Get-AkText 'init.root' 'Root    : {0}' $Root)
Write-Host (Get-AkText 'init.agents' 'Agents  : {0}' $(if ($names.Count) { $names -join ', ' } else { Get-AkText 'init.agents.none' '(none registered yet)' }))
Write-Host (Get-AkText 'init.created' 'Created : registry/ mailboxes/<agent>/{inbox,processing,outbox,sent,notes} archive/ logs/ templates/ post/{manifest,cold}')
Write-Host (Get-AkText 'init.wake1' 'Wake    : agents without a wake command use PULL mode (they run mail-check themselves);')
Write-Host (Get-AkText 'init.wake2' '          agents with wake use PUSH mode (send.ps1 spawns their CLI right after delivery;')
Write-Host (Get-AkText 'init.wake3' '          watch.ps1 is the fallback daemon).')
Write-Host (Get-AkText 'init.next' 'Next    : start scripts\watch.ps1 (fallback), open dashboard\dashboard.html')

Update-Dashboard
