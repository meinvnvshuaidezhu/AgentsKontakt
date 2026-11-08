param(
  [Parameter(Mandatory=$true)][string]$File,
  [switch]$NoDispatch,
  [string]$Root = '',
  # Bounded grace after spawning an exec wake command: a wake command that
  # dies inside this window is a launch failure (missing CLI, bad path, crash)
  # and the channel counts as failed. Long sessions are NOT waited for - their
  # terminal state is written later by exec-dispatch-watch.ps1. Sized for the
  # watcher + child PowerShell startup (~1-1.5s) plus margin.
  [int]$ExecProbeMs = 3000,
  # Retry bound for one letter: when its .progress sidecar shows this many
  # DISPATCHED lines (the claim marker appended on every dispatch round), the
  # letter is returned to its sender instead of woken again. -1 = take config
  # dead_after_dispatches (default 3); 0 = never (legacy infinite retry).
  [int]$MaxDispatches = -1,
  # Fresh-activity window (minutes) for the recipient busy check.
  [int]$BusyMinutes = 30
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        # the script may sit in a subdir - walk up to the data root (a dir holding registry\)
        $d = $PSScriptRoot
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if ($d) { $Root = $d } elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
        else { $Root = (Get-Location).Path }
    }
}
. (Join-Path $PSScriptRoot 'common.ps1')

if ($MaxDispatches -lt 0) {
    $cfgR = Get-SystemConfig
    $vR = [string]$cfgR['dead_after_dispatches']
    if ($vR -match '^\d+$') { $MaxDispatches = [int]$vR } else { $MaxDispatches = 3 }
}

# Event router. Called by send.ps1 right after delivery (immediate notify),
# by watch.ps1 on delivery events, and by the watch sweep.
# The claim (move inbox->processing) doubles as the dedupe/lock: two routers
# racing on the same message resolve into exactly one winner.
#
# Notification channels (registry wake field). The card may list a priority
# chain separated by "|"; the router rings them in order and stops at the
# first success. Priority convention (stability x timeliness, see PROTOCOL 0):
# exec > webhook > mailto; a TODO-only wake means PULL (leave in inbox).
#   exec <command>        -> spawn command headlessly ({prompt} replaced);
#                            a bare command without a known prefix is exec
#   webhook <url>         -> POST a JSON doorbell (message_path included)
#   mailto <address>      -> notification email via config\smtp.json
# Channels are doorbells only: the mailbox stays the source of truth and the
# work contract (progress heartbeat, reply via send.ps1) is channel-independent.
# If every channel in the chain fails, the message is moved back to the inbox
# so the sweep retries (PULL-equivalent; no mail is lost).

if (-not (Test-Path -LiteralPath $File)) { exit 0 }              # lost race or gone
$File = (Get-Item -LiteralPath $File).FullName                   # canonical long path
if ($File -notmatch '\\inbox\\') { exit 0 }                      # only inbox arrivals
$agent = Get-AgentFromPath -FilePath $File
if (-not $agent) { exit 0 }

$agents = Get-RegisteredAgents
$reg = $agents | Where-Object { $_.name -eq $agent }
$wake = ''
if ($reg) { $wake = [string]$reg.wake }

if ([string]::IsNullOrWhiteSpace($wake) -or $wake -match 'TODO') {
    # PULL mode: leave the message in the inbox so the agent can pick it up
    # itself (mail-check). Warn only once per message via a flag file.
    $fm0 = Read-FrontMatter -Path $File
    $mid0 = [string]$fm0['id']
    if (-not $mid0) { $mid0 = [System.IO.Path]::GetFileNameWithoutExtension($File) }
    if (-not (Test-RouteFlag -MessageId $mid0)) {
        Set-RouteFlag -MessageId $mid0
        Write-Journal -Agent $agent -Action 'WARN' -Detail ('no wake command (PULL mode); message ' + $mid0 + ' waits in inbox for mail-check pickup')
        Write-SystemLog ('PULL-mode arrival for ' + $agent + ': ' + $mid0)
    }
    exit 0
}

# Parse the priority chain: "exec <cmd> | webhook <url> | mailto <addr>".
# Bare items without a known prefix are exec (backward compatibility).
$chain = @(($wake -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$inboxDir = Split-Path $File -Parent

# --- dispatch guards (claim-only / -NoDispatch runs skip them) --------------
# Two livelock breakers, both evaluated BEFORE the claim move so a skipped
# letter costs zero state changes:
#   1. attempts exhausted -> return the letter to its sender (master stamped
#      RETURNED + bounce mail). Without a bound, a letter whose recipient
#      never answers cycles requeue -> claim -> wake forever (observed
#      2026-10-25..29: five letters, ~2700 wasted CLI sessions, a full
#      headless session every ~20 minutes).
#   2. recipient busy -> leave the letter in the inbox, wake nobody. A
#      single-session CLI rejects a second wake within seconds anyway, so
#      each attempt against a busy peer burned a watcher + CLI spawn per
#      sweep. The sweep re-routes once the session goes quiet.
if (-not $NoDispatch) {
    $side0 = [System.IO.Path]::ChangeExtension($File, '.progress')
    $attempts = 0
    if (Test-Path -LiteralPath $side0) {
        try {
            foreach ($ln in [System.IO.File]::ReadAllLines($side0)) {
                if ($ln -match 'DISPATCHED \(post office') { $attempts++ }
            }
        } catch {}
    }
    if ($MaxDispatches -gt 0 -and $attempts -ge $MaxDispatches) {
        $fm0 = Read-FrontMatter -Path $File
        $mid0 = [string]$fm0['id']
        if (-not $mid0) { $mid0 = [System.IO.Path]::GetFileNameWithoutExtension($File) }
        $from0 = [string]$fm0['from']
        $topic0 = [string]$fm0['topic']
        Remove-Item -LiteralPath $File -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $File) {
            # Copy is locked (reader/AV): returning now would bounce on every
            # later sweep too. Retry the removal first; bounce once it is gone.
            Write-SystemLog ('route: exhausted copy could not be removed (locked?), retrying later: ' + $File)
            exit 0
        }
        if (Test-Path -LiteralPath $side0) { Remove-Item -LiteralPath $side0 -Force -ErrorAction SilentlyContinue }
        if ($mid0 -like 'sys-*') {
            # service mail has no actionable sender mailbox: drop, log only
            Write-SystemLog ('route: sys mail dropped after ' + $attempts + ' dispatch attempts: ' + $mid0)
            Write-Journal -Agent $agent -Action 'WARN' -Detail ('sys mail ' + $mid0 + ' dropped after ' + $attempts + ' dispatch attempts')
        } elseif ($from0 -and $topic0) {
            $reason0 = ('dispatch attempts exhausted (' + $attempts + ' wakes, no answer)')
            $master0 = Join-Path (Join-Path (Join-Path $script:DirMailboxes $from0) 'sent') ($mid0 + '.md')
            if (Test-Path -LiteralPath $master0) {
                Set-MailStatus -MessagePath $master0 -Status 'RETURNED' -Reason $reason0 | Out-Null
            }
            $body0 = (Get-AkLines 'route.deadletter.body' 'The post office stopped re-dispatching this mail after {0} wake attempts with no answer.' '' 'id: {1}' 'recipient: {2}' 'topic: {3}' '' 'The recipient copy was removed; your master stays in sent (status RETURNED). Options: nudge the recipient, resend as a NEW message id, or close the topic.' |
                ForEach-Object { $_ -f $attempts, $mid0, $agent, $topic0 }) -join "`r`n"
            $bounce0 = Write-SystemMail -To $from0 -Topic $topic0 -Subject ('RETURNED ' + $mid0) -Body $body0 -InReplyTo $mid0
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'route.ps1') -File $bounce0 -Root $Root 2>&1
            Write-Journal -Agent $agent -Action 'WARN' -Detail ($mid0 + ' | returned to ' + $from0 + ': ' + $reason0)
            Write-SystemLog ('route: ' + $reason0 + ' - ' + $mid0 + ' returned to ' + $from0)
        } else {
            Write-Journal -Agent $agent -Action 'WARN' -Detail ($mid0 + ' | dropped: attempts exhausted and envelope lacks from/topic')
        }
        Write-Host (Get-AkText 'route.returned-exhausted' 'RETURNED {0} - attempts exhausted ({1})' $mid0 $attempts)
        exit 0
    }
    if (Test-AgentBusy -AgentDir (Split-Path $inboxDir -Parent) -FreshMinutes $BusyMinutes) {
        $fm0 = Read-FrontMatter -Path $File
        $mid0 = [string]$fm0['id']
        if (-not $mid0) { $mid0 = [System.IO.Path]::GetFileNameWithoutExtension($File) }
        if (-not (Test-RouteFlag ($mid0 + '.busy'))) {
            Set-RouteFlag ($mid0 + '.busy')
            Write-Journal -Agent $agent -Action 'WARN' -Detail ($mid0 + ' | recipient busy - wake deferred until its session goes quiet')
        }
        Write-Host (Get-AkText 'route.queued-busy' 'QUEUED-BUSY {0}' $mid0)
        exit 0
    }
}

# Claim first: the move is the mutex, so each message rings the doorbell once.
$procDir  = Join-Path (Split-Path $inboxDir -Parent) 'processing'
try {
    $claimed = Move-Atomic -File $File -DestDir $procDir
} catch {
    Write-SystemLog ('route claim failed: ' + $File + ' :: ' + $_.Exception.Message)
    exit 1
}

# Carry a requeued dispatch sidecar along with the letter. The claim used to
# move only the .md, orphaning inbox\<id>.progress on every requeue cycle;
# carrying it keeps the DISPATCHED-line count intact - that count is the
# attempts meter the exhaustion guard above reads.
$sideIn = Join-Path $inboxDir ([System.IO.Path]::GetFileNameWithoutExtension($File) + '.progress')
if (Test-Path -LiteralPath $sideIn) {
    try { Move-Atomic -File $sideIn -DestDir $procDir | Out-Null } catch {
        Write-SystemLog ('route sidecar carry failed for ' + $File + ' :: ' + $_.Exception.Message)
    }
}

# initial heartbeat: the other side (and cleanup) can see dispatch happened
$side = Join-Path $procDir ([System.IO.Path]::GetFileNameWithoutExtension($claimed) + '.progress')
$hb = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] DISPATCHED (post office notifying via registered channels)'
[System.IO.File]::AppendAllText($side, $hb + "`r`n", $script:UTF8Bom)

# Byte offset of the sidecar as this dispatch begins. A requeued message
# carries its sidecar back to the inbox, stale STATUS lines included; only
# bytes appended after this offset describe the current attempt.
$script:SideBaseLen = (Get-Item -LiteralPath $side).Length

Update-RegistryField -Agent $agent -Key 'last_seen' -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') | Out-Null

$fm = Read-FrontMatter -Path $claimed
$mid = [string]$fm['id']
if (-not $mid) { $mid = [System.IO.Path]::GetFileNameWithoutExtension($claimed) }
Write-Journal -Agent $agent -Action 'CLAIM' -Detail ("{0} | topic={1}" -f $mid, $fm['topic'])

if ($NoDispatch) { Write-Host (Get-AkText 'route.claimed-no-dispatch' 'CLAIMED(no-dispatch) {0}' $mid); exit 0 }

# Per-channel doorbells. Each returns $true when the doorbell was rung; the
# spawned/notified party then owns progress. Failures throw to the caller.
#
# Exec terminal state (PROTOCOL 0.5 item 4): the exec channel is the only one
# with a process to observe, so Invoke-ExecDispatch hands the wake command to a
# detached watcher (exec-dispatch-watch.ps1) which appends
#   STATUS ok  /  STATUS failed code=<n> reason=<...>
# to the sidecar when the command really ends. That closes the "spawned but
# died instantly" blind spot: a bare wrapper used to exit in milliseconds with no
# trace while the journal still said DISPATCHED.
function Get-ProgressAppended {
    # Sidecar bytes appended since this dispatch began (stale STATUS lines from
    # an earlier attempt do not count).
    try {
        if (-not (Test-Path -LiteralPath $side)) { return '' }
        $fs = [System.IO.File]::Open($side, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -le $script:SideBaseLen) { return '' }
            $fs.Seek($script:SideBaseLen, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] ($len - $script:SideBaseLen)
            $read = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Close() }
    } catch { return '' }
}

function Get-LastAppendedStatus {
    # Last STATUS line of the current attempt ('' when there is none yet).
    $tail = Get-ProgressAppended
    $lines = @($tail -split "`r?`n" | Where-Object { $_ -match '^STATUS\s' })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1]
}

function Add-ProgressStatus {
    param([string]$Line)
    try {
        if (Test-Path -LiteralPath $side) {
            [System.IO.File]::AppendAllText($side, $Line + "`r`n", $script:UTF8Bom)
        }
    } catch {
        Write-SystemLog ('progress status write failed for ' + $mid + ' :: ' + $_.Exception.Message)
    }
}

function Invoke-ExecDispatch {
    param([string]$Cmd)
    $prompt = [string](Read-TextFile -Path (Join-Path $script:DirTemplates 'dispatch-prompt.txt'))
    $prompt = $prompt.Trim().Replace('{path}', $claimed)
    $prompt = $prompt.Replace("'", '').Replace('"', '')
    $cmdLine = $Cmd.Replace('{prompt}', "'" + $prompt + "'")

    $watcher = Join-Path $PSScriptRoot 'exec-dispatch-watch.ps1'
    if (-not (Test-Path -LiteralPath $watcher)) { throw ('exec watcher missing: ' + $watcher) }

    # Reset the baseline: when this channel is a fallback after a failed exec
    # attempt, the earlier STATUS line must not be mistaken for this attempt's.
    if (Test-Path -LiteralPath $side) { $script:SideBaseLen = (Get-Item -LiteralPath $side).Length } else { $script:SideBaseLen = 0 }

    # The payload travels base64-encoded: command lines embed prompts with
    # spaces/quotes and must not be re-quoted by the argv boundary.
    $payload = @{
        cmdLine   = $cmdLine
        progress  = $side
        agent     = $agent
        messageId = $mid
        root      = $Root
        log       = (Join-Path (Join-Path $script:DirLogs $agent) 'dispatch.log')
    } | ConvertTo-Json -Compress
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))

    # -WindowStyle Hidden: SW_HIDE is applied at process creation, so the
    # dispatch console (and the node child inheriting it) never pops up.
    # -WorkingDirectory $Root: wake commands may use root-relative paths,
    # which keeps registry cards portable across machines/drives.
    Start-Process -FilePath 'powershell' -WindowStyle Hidden -WorkingDirectory $Root `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $watcher, '-Payload', $b64) | Out-Null

    # Bounded grace, never the session lifetime (minutes to hours). If the wake
    # command dies inside it the watcher has already stamped the sidecar, so the
    # channel counts as failed: the chain degrades, or the mail is requeued,
    # instead of a DISPATCH that never happened.
    $grace = [Math]::Max(200, $ExecProbeMs)
    $deadline = (Get-Date).AddMilliseconds($grace)
    while ((Get-Date) -lt $deadline) {
        $tail = Get-ProgressAppended
        if ($tail -match '(?m)^STATUS\s') {
            if ($tail -match '(?m)^STATUS\s+failed\s+code=(-?\d+)') {
                throw ('exec wake exited immediately (code=' + $Matches[1] + ')')
            }
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

function Invoke-WebhookDispatch {
    param([string]$Url)
    $payload = @{
        type         = 'agents-kontakt'
        id           = $mid
        topic        = [string]$fm['topic']
        from         = [string]$fm['from']
        subject      = [string]$fm['subject']
        message_path = $claimed
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $Url -Body $payload -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    return $true
}

function Invoke-MailtoDispatch {
    param([string]$Addr)
    $cfgPath = Join-Path $script:Root 'config\smtp.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { throw 'smtp config missing (config\smtp.json)' }
    $cfg = Read-TextFile -Path $cfgPath | ConvertFrom-Json
    if (-not $cfg.host) { throw 'smtp config has no host' }
    $body = (Get-AkLines 'route.mailto.body' 'New mail in your AgentsKontakt mailbox.' '' 'id: {0}' 'topic: {1}' 'from: {2}' 'file: {3}' '' 'Read PROTOCOL.md in the shared root and handle this message.' |
        ForEach-Object { $_ -f $mid, [string]$fm['topic'], [string]$fm['from'], $claimed }) -join "`r`n"
    $mail = @{
        SmtpServer = [string]$cfg.host
        From       = [string]$cfg.from
        To         = $Addr
        Subject    = (Get-AkText 'route.mailto.subject' 'AgentsKontakt new mail: {0}' $mid)
        Body       = $body
        Encoding   = [System.Text.Encoding]::UTF8
    }
    if ($cfg.port) { $mail['Port'] = [int]$cfg.port }
    if ($cfg.ssl)  { $mail['UseSsl'] = $true }
    if ($cfg.user) {
        $cred = New-Object System.Management.Automation.PSCredential([string]$cfg.user, (ConvertTo-SecureString ([string]$cfg.pass) -AsPlainText -Force))
        $mail['Credential'] = $cred
    }
    Send-MailMessage @mail
    return $true
}

# Ring the chain in priority order; stop at the first channel that answers.
$ok = $false; $usedChan = ''; $failNotes = @()
foreach ($item in $chain) {
    $chan = 'exec'; $param = $item
    if ($item -match '^(exec|webhook|mailto)\s+(.+)$') { $chan = $Matches[1]; $param = $Matches[2].Trim() }
    elseif ($item -match '^(a2a|mqtt|im)(\s|$)') {
        # Menu-listed but not yet implemented in the post office; must never
        # happen (registration rule: implement the dispatch function first).
        Write-Journal -Agent $agent -Action 'WARN' -Detail ($Matches[1] + ' channel not implemented in post office - skipped for ' + $mid)
        continue
    }
    try {
        $ok = switch ($chan) {
            'webhook' { Invoke-WebhookDispatch -Url $param }
            'mailto'  { Invoke-MailtoDispatch -Addr $param }
            default   { Invoke-ExecDispatch -Cmd $param }
        }
    } catch {
        $failNotes += ($chan + ': ' + $_.Exception.Message)
        Write-Journal -Agent $agent -Action 'WARN' -Detail ($chan + ' notify failed for ' + $mid + ': ' + $_.Exception.Message)
        $ok = $false
    }
    if ($ok) { $usedChan = $chan; break }
}

# A wake command can die a few hundred ms after the grace expired, so its
# STATUS failed line can land between the poll loop's last look and this point.
# A channel that has already reported failure must not be recorded DISPATCHED.
if ($ok -and $usedChan -eq 'exec' -and $failNotes.Count -eq 0) {
    $last = Get-LastAppendedStatus
    if ($last -match '^STATUS\s+failed') {
        $ok = $false
        $failNotes += ('exec: ' + $last)
        Write-Journal -Agent $agent -Action 'WARN' -Detail ('exec notify failed for ' + $mid + ': ' + $last + ' (landed at the grace boundary)')
    }
}

if ($ok) {
    Write-Journal -Agent $agent -Action 'DISPATCH' -Detail ($mid + ' via ' + $usedChan)
    # A dead earlier channel may already have left STATUS failed on the
    # sidecar; the last STATUS line must describe the channel that really
    # carries the mail, so clear that with a fallback acknowledgement.
    if ((Get-LastAppendedStatus) -match '^STATUS\s+failed') {
        Add-ProgressStatus ('STATUS ok via ' + $usedChan)
    }
    Write-Host (Get-AkText 'route.dispatched' 'DISPATCHED {0} -> {1} ({2})' $mid $agent $usedChan)
} else {
    # Every agreed channel failed. Leave the terminal state on the sidecar
    # (unless a channel already stamped one), then move the message and its
    # sidecar back to the inbox so the next sweep retries - PULL-equivalent,
    # no mail is lost.
    if ((Get-LastAppendedStatus) -notmatch '^STATUS\s+failed') {
        $code = '1'
        $joined = ($failNotes -join '; ')
        if ($joined -match 'code=(-?\d+)') { $code = $Matches[1] }
        $reason = $joined
        if (-not $reason) { $reason = 'all notify channels failed' }
        $reason = ($reason -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
        Add-ProgressStatus ('STATUS failed code=' + $code + ' reason=' + $reason)
    }
    Move-Atomic -File $claimed -DestDir $inboxDir | Out-Null
    $sidePath = Join-Path $procDir ([System.IO.Path]::GetFileNameWithoutExtension($claimed) + '.progress')
    if (Test-Path -LiteralPath $sidePath) { Move-Atomic -File $sidePath -DestDir $inboxDir | Out-Null }
    Write-Journal -Agent $agent -Action 'WARN' -Detail ('all notify channels failed for ' + $mid + ' - requeued to inbox')
    Write-Host (Get-AkText 'route.notify-failed' 'NOTIFY-FAILED {0} - all channels failed, requeued to inbox' $mid)
    exit 1
}
