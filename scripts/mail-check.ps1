param(
  [Parameter(Mandatory=$true)][string]$Agent,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# PULL-mode entry point: an agent runs this at task start / end to check its own mail.
# Exit code 0 = nothing to do, 1 = there is mail (handy for hooks).

$agents = Get-RegisteredAgents
$reg = $agents | Where-Object { $_.name -eq $Agent }
if (-not $reg) { Write-Output (Get-AkText 'mailcheck.not-registered' 'MAILBOX: agent not registered: {0}' $Agent); exit 2 }

$agentDir = Split-Path (Join-Path $Root ([string]$reg.inbox)) -Parent
$new = @()
$claimed = @()
$inboxDir = Join-Path $agentDir 'inbox'
$procDir  = Join-Path $agentDir 'processing'
if (Test-Path -LiteralPath $inboxDir) { $new = @(Get-ChildItem -LiteralPath $inboxDir -File -Filter '*.md' -ErrorAction SilentlyContinue) }
if (Test-Path -LiteralPath $procDir)  { $claimed = @(Get-ChildItem -LiteralPath $procDir -File -Filter '*.md' -ErrorAction SilentlyContinue) }

Update-RegistryField -Agent $Agent -Key 'last_seen' -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') | Out-Null

if ($new.Count -eq 0 -and $claimed.Count -eq 0) {
    Write-Output (Get-AkText 'mailcheck.no-pending' 'MAILBOX: no pending mail for {0}' $Agent)
    exit 0
}

Write-Output (Get-AkText 'mailcheck.pending-count' 'MAILBOX: {0} pending message(s) for {1}' ($new.Count + $claimed.Count) $Agent)
foreach ($f in $new) {
    # v3 chain copy: one overwrite-style view per topic; state lives in
    # post\threads\<topic>\status.json (claim via claim.ps1 flips it to processing).
    if ($f.Name -match '\.chain\.md$') {
        $t = $f.Name -replace '\.chain\.md$', ''
        $st = Get-TopicStatus -Topic $t
        $state = if ($st) { [string]$st.state } else { 'unknown' }
        $fromV3 = if ($st) { [string]$st.from } else { '' }
        Write-Output ('  TOPIC    {0}  state={1}  from={2}  (v3 chain copy; claim flips state to processing)' -f $f.Name, $state, $fromV3)
        continue
    }
    $fm = Read-FrontMatter -Path $f.FullName
    # v3 unofficial gate (§2.6): a msg-*.md whose topic has no v3 trace and no
    # v2 SEND record is a shadow letter - flagged for the reader, still listed.
    $tag = ''
    $t0 = [string]$fm['topic']
    if ($t0 -and ($f.BaseName -notlike 'sys-*')) {
        $trace = Test-TopicTrace -Topic $t0 -From ([string]$fm['from']) -To ([string]$fm['to'])
        if ($trace -eq 'legacy-suspect') { $tag = '  [unofficial: no v3 trace and no v2 SEND record - verify the sender]' }
    }
    Write-Output (Get-AkText 'mailcheck.new' '  NEW      {0}  from={1}  topic={2}  type={3}' $f.Name $fm['from'] $fm['topic'] $fm['type'])
    if ($tag) { Write-Output $tag }
    Write-Output (Get-AkText 'mailcheck.claim-hint' '           -> claim it first: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\claim.ps1 -File "{0}"' $f.FullName)
}
foreach ($f in $claimed) {
    $fm = Read-FrontMatter -Path $f.FullName
    Write-Output (Get-AkText 'mailcheck.claimed' '  CLAIMED  {0}  from={1}  topic={2}  type={3}  (already claimed, handle it)' $f.Name $fm['from'] $fm['topic'] $fm['type'])
}
exit 1
