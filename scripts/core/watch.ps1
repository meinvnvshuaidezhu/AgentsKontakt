param(
  [int]$MaxSeconds  = 0,   # 0 = run until Ctrl+C
  [int]$SweepSeconds = 120, # reconciliation interval while mail is moving (safety net for missed events; mail routing itself is FSW event-driven)
  [int]$IdleSeconds  = 300, # reconciliation interval when nothing happened since the last sweep (idle CPU diet)
  [string]$Root = ''
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

# --- single-instance guard: exactly one office loop per data root ------------
# History: a crashed or task-killed tray app used to leave its powershell loop
# behind, and the next app start spawned a second one - two loops swept every
# 60s at ~13% CPU each, forever. Two mechanisms fix it:
#   1. mutex first (2026-10-29 ordering): a newcomer that cannot take the mutex
#      exits WITHOUT touching anyone. The old order - adopt first, then take
#      the mutex - let a newcomer kill a healthy office that merely held the
#      mutex, and the tray app's monitor respawned over that: kill/respawn
#      ping-pong storms (observed 2026-10-28 08:30, three loops fighting).
#   2. adoption while HOLDING the mutex: anything else still running watch.ps1
#      on THIS root is then by definition an orphan nobody supervises - kill it.
# Skipped under -MaxSeconds: transient test/watchdog runs must not kill or
# block the resident office.
if ($MaxSeconds -le 0) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $mh = [BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Root.ToLower()))) -replace '-', ''
    $md5.Dispose()
    $script:WatchMutex = New-Object System.Threading.Mutex($false, ('Global\AKWATCH_' + $mh.Substring(0, 16)))
    $owned = $false
    try { $owned = $WatchMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }   # previous holder died mid-hold: it is gone
    if (-not $owned) {
        Write-SystemLog 'watch: another loop already holds this office - exiting'
        $WatchMutex.Dispose()
        exit 0
    }
    $adopted = @()
    foreach ($wp in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($wp.ProcessId -eq $PID) { continue }
        $cl = [string]$wp.CommandLine
        # Anchor on a path separator: 'watch\.ps1' as a bare substring also
        # matches exec-dispatch-watch.ps1 (route.ps1's exec-channel watcher,
        # a legitimate delivery infrastructure child) and killed it for days.
        if (-not $cl -or $cl -notmatch '[/\\]watch\.ps1') { continue }
        if ($cl -match '-MaxSeconds\s+\d') { continue }   # transient test run - leave it
        $m = [regex]::Match($cl, '-File\s+"?([^"]*[/\\]watch\.ps1)')
        if (-not $m.Success) { continue }
        $d = Split-Path -Parent ($m.Groups[1].Value -replace '"', '')
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if (-not $d -or [string]::Compare($d, $Root, $true) -ne 0) { continue }   # different root - not ours
        try { Stop-Process -Id $wp.ProcessId -Force -ErrorAction Stop; $adopted += $wp.ProcessId } catch {}
    }
    if ($adopted.Count) { Write-SystemLog ('watch: took over from stale loop(s): pid ' + ($adopted -join ',pid ')) }
}

Initialize-Tree

# --- poll doorbell (v2.2): config\system.json poll_hooks = { agent: command }.
# On inbox arrival the loop debounces ~2s (a delivery is several FSW events),
# then fires the command once with {count} = pending non-sys inbox letters and
# {root} = data root, plus a POLL journal entry - the observable behavior of
# scripts\poll.py without the per-minute process spawn. poll.py stays for
# agents that schedule it from their own hosts/platforms.
$script:DoorbellHooks = @{}
$script:DoorbellPend = @{}
try {
    $dh = (Get-SystemConfig)['poll_hooks']
    if ($dh) {
        foreach ($pr in $dh.PSObject.Properties) { $script:DoorbellHooks[$pr.Name] = [string]$pr.Value }
    }
} catch { Write-SystemLog ('poll_hooks config unreadable: ' + $_.Exception.Message) }

$fsw = New-Object System.IO.FileSystemWatcher($script:DirMailboxes)
$fsw.IncludeSubdirectories = $true
$fsw.InternalBufferSize    = 65536
$fsw.EnableRaisingEvents   = $true
$sub1 = Register-ObjectEvent -InputObject $fsw -EventName Renamed
$sub2 = Register-ObjectEvent -InputObject $fsw -EventName Created
Write-SystemLog ('watch started (root=' + $Root + ')')

function Invoke-RouteSafe {
    # Route in a DETACHED child process. Route does real IO: it may claim the
    # letter, pull the recipient's wake chain and (for PUSH agents) spawn a
    # headless CLI - measured at ~1.7s per call. Doing that inline on the
    # event pump blocks it for the whole duration: during a startup sweep with
    # a backlog, every outbox take-bell queues behind the inbox routing and
    # the 60s reconciliation tick never fires. Offloading keeps the pump
    # responsive; the move-as-mutex in route.ps1 still guarantees one winner
    # per letter, so concurrent routes are safe.
    param([string]$Path)
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                            (Join-Path $PSScriptRoot 'route.ps1'),
                            '-File', ('"' + $Path + '"'),
                            '-Root', ('"' + $script:Root + '"')) `
            -WindowStyle Hidden -WorkingDirectory $script:Root | Out-Null
    } catch {
        Write-SystemLog ('route spawn failed for ' + $Path + ' :: ' + $_.Exception.Message)
    }
}

function Invoke-TakeoutSafe {
    # Post-office take-out: validate, contact, copy-deliver, receipt/bounce.
    # -Root is explicit: send.ps1 must never resolve a different root.
    # Detached for the same reason as Invoke-RouteSafe: send.ps1 does the
    # copy delivery plus a full wake-chain attempt (~5.8s measured). Inline,
    # it stalls the event pump and delays every later take-bell.
    param([string]$Path)
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                            (Join-Path $PSScriptRoot '..\send.ps1'),
                            '-File', ('"' + $Path + '"'),
                            '-Root', ('"' + $script:Root + '"')) `
            -WindowStyle Hidden -WorkingDirectory $script:Root | Out-Null
    } catch {
        Write-SystemLog ('takeout spawn failed for ' + $Path + ' :: ' + $_.Exception.Message)
    }
}

function Get-StallMinutes {
    # Stall window for the sender's in-flight mail; optional card field
    # stall_after=<minutes>, default 30. Pre-parsed by Get-RegisteredAgents.
    param([string]$AgentName)
    foreach ($a in (Get-RegisteredAgents)) {
        if ([string]$a.name -eq $AgentName) { return [int]$a.stall_after }
    }
    return 30
}

function Invoke-MonitorInflight {
    # In-flight tracking (v2): mirror recipient activity (mail mtime, heartbeat
    # mtime, thinking-record mtime) into the sender's master status sidecar,
    # and raise a stall report when nothing moved for the whole window.
    #
    # Passive by default: every sweep only STATS the tracked files and compares
    # against the ledger (post\inflight.ledger). A file whose stats did not move
    # costs zero reads and zero parses; only mtime changes (letter moved,
    # heartbeat or notes updated, sidecar rewritten) or a stall clock running
    # out drop it into the full examination path below. The fast path reads
    # mtimes only - never message, sidecar or notes content.
    #
    # v2.2: the sent walk reads from the sweep's one-pass tree scan instead of
    # a cmdlet Get-ChildItem per agent (each directory probe costs ~50ms on
    # this volume). Fingerprints and ledger format are unchanged.
    param([hashtable]$Scan)
    $ledgerPath = Join-Path $script:DirPost 'inflight.ledger'
    $ledger = @{}
    if (Test-Path -LiteralPath $ledgerPath) {
        foreach ($ln in [System.IO.File]::ReadAllLines($ledgerPath)) {
            $p = $ln -split "`t"
            if ($p.Count -ge 14) { $ledger[$p[0]] = $p }
        }
    }
    $seen = @{}

    function Get-Fp {   # existence-guarded stat fingerprint "<len>:<ticks>", or "0"
        param([string]$Path)
        if (-not $Path) { return '0' }
        try {
            $fi = New-Object System.IO.FileInfo($Path)
            if ($fi.Exists) { return ('{0}:{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) }
        } catch {}
        return '0'
    }

    foreach ($a in (Get-RegisteredAgents)) {
        $sender = [string]$a.name
        $sent = Join-Path (Join-Path $script:DirMailboxes $sender) 'sent'
        if (-not (Test-Path -LiteralPath $sent)) { continue }
        $stallMin = Get-StallMinutes -AgentName $sender
        foreach ($path in (Get-ScanZoneFiles -Scan $Scan -Agent $sender -Zone 'sent')) {
            $seen[$path] = $true
            $mdFp = $Scan[$path]
            $sideFp = Get-Fp -Path ([System.IO.Path]::ChangeExtension($path, '.status'))
            $e = $ledger[$path]
            if ($e) {
                $state = $e[3]
                $sameInputs = ($e[1] -eq $mdFp -and $e[2] -eq $sideFp -and
                               $e[6] -eq (Get-Fp -Path $e[5]) -and $e[8] -eq (Get-Fp -Path $e[7]) -and
                               $e[10] -eq (Get-Fp -Path $e[9]) -and $e[12] -eq (Get-Fp -Path $e[11]))
                if ($sameInputs) {
                    if ($state -in @('RETURNED','REPLIED','ARCHIVED')) { continue }   # settled and untouched
                    $actTicks = [long]0
                    try { $actTicks = [long]$e[13] } catch {}
                    $idleMin = ((Get-Date) - (New-Object datetime($actTicks))).TotalMinutes
                    if ($idleMin -le $stallMin -or $state -eq 'STALLED') { continue }   # quiet; STALLED re-reporting is suppressed anyway
                }
            }

            # ---- full examination (identical decisions to the pre-ledger code) ----
            $st = Get-MailStatus -MessagePath $path
            if (-not $st.Count -or -not $st['peer']) { continue }
            $state = [string]$st['status']
            if ($state -in @('RETURNED','REPLIED','ARCHIVED')) { continue }
            $id = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $peer = [string]$st['peer']
            $peerDir = Join-Path $script:DirMailboxes $peer
            $copy = $null; $where = ''
            $procPath = $null; $inbPath = $null
            foreach ($pair in @(@('processing','IN_PROGRESS'), @('inbox','DELIVERED'))) {
                $cand = Join-Path (Join-Path $peerDir $pair[0]) ($id + '.md')
                if (Test-Path -LiteralPath $cand) {
                    $copy = $cand; $where = $pair[1]
                    if ($pair[0] -eq 'processing') { $procPath = $cand } else { $inbPath = $cand }
                    break
                }
            }
            $progPath = $null; $notePath = $null
            $act = Get-ScanTime -Fp $mdFp
            if (-not $act) { $act = (Get-Date) }
            if ($copy) {
                $act = (Get-Item -LiteralPath $copy).LastWriteTime
                $progPath = Join-Path (Split-Path $copy -Parent) ($id + '.progress')
                if (Test-Path -LiteralPath $progPath) {
                    $m = (Get-Item -LiteralPath $progPath).LastWriteTime; if ($m -gt $act) { $act = $m }
                }
                $topic = [string]$st['topic']
                if ($topic) {
                    $notePath = Join-Path (Join-Path $peerDir 'notes') ($topic + '.md')
                    if (Test-Path -LiteralPath $notePath) {
                        $m = (Get-Item -LiteralPath $notePath).LastWriteTime; if ($m -gt $act) { $act = $m }
                    }
                }
            } elseif ($state -ne 'DISPATCHING') {
                continue   # archived/closed or mid-move; close.ps1 finalizes
            }
            # mirror activity that is newer than the recorded stamp
            $recorded = $null
            try { $recorded = [datetime]::Parse([string]$st['updated']) } catch {}
            if ($recorded -and $act -gt $recorded -and $where) {
                Set-MailStatus -MessagePath $path -Status $where | Out-Null
                Write-Journal -Agent $sender -Action 'TRACK' -Detail ($id + ' | ' + $where + ' | activity=' + $act.ToString('HH:mm:ss'))
                $state = $where
            }
            # stall: nothing moved for the whole window -> report once per episode
            $idleMin = ((Get-Date) - $act).TotalMinutes
            if ($idleMin -gt $stallMin -and $state -ne 'STALLED') {
                $reason = if (-not $copy) { 'dispatch interrupted' } else { ('no activity for ' + [int]$idleMin + ' min') }
                Set-MailStatus -MessagePath $path -Status 'STALLED' -Reason $reason | Out-Null
                Write-Journal -Agent $sender -Action 'STALL' -Detail ($id + ' | ' + $reason)
                $body = (Get-AkLines 'watch.stalled.body' 'No activity on this in-flight mail for the stall window.' '' 'id: {0}' 'recipient: {1}' 'last activity: {2}' '' 'Options: nudge the recipient, resend, or close the topic. The master stays in your sent area either way.' |
                    ForEach-Object { $_ -f $id, $peer, $act.ToString('yyyy-MM-dd HH:mm:ss') }) -join "`r`n"
                $mail = Write-SystemMail -To $sender -Topic ([string]$st['topic']) -Subject ('STALLED ' + $id) -Body $body
                $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'route.ps1') -File $mail -Root $script:Root 2>&1
            }
            # remember exactly what this examination saw, so quiet files skip
            $ledger[$path] = @($path, $mdFp, $sideFp, $state, $peer,
                               $procPath, (Get-Fp -Path $procPath), $inbPath, (Get-Fp -Path $inbPath),
                               $progPath, (Get-Fp -Path $progPath), $notePath, (Get-Fp -Path $notePath),
                               [string]$act.Ticks)
        }
    }
    # write back only what still exists (vanished letters leave the ledger)
    if ($seen.Count -ne $ledger.Count) { 
        foreach ($k in @($ledger.Keys)) { if (-not $seen.ContainsKey($k)) { $ledger.Remove($k) } }
    }
    $lines = @($ledger.Values | ForEach-Object { $_ -join "`t" })
    [System.IO.File]::WriteAllLines($ledgerPath, $lines, $script:UTF8Bom)
}

function Invoke-Sweep {
    # Reconciliation pass. Inbox: route unclaimed arrivals (skip sys-* service
    # mails - they are informational and never wake anyone). Outbox: take
    # letters whose last write is older than the quiet window (direct writers
    # without the .tmp rename convention get picked up here).
    #
    # Dispatch is detached (see Invoke-RouteSafe / Invoke-TakeoutSafe), so
    # this loop only *spawns* children and returns fast. The outbox loop runs
    # BEFORE the inbox loop: a letter waiting to be picked up must not sit
    # behind a backlog of arrivals (that ordering once delayed a take-bell
    # by four minutes).
    # Stage telemetry in CPU-ms: wall time would count retry sleeps as work,
    # which is exactly the distinction needed to find real CPU burners.
    function Get-CpuMs {
        return [System.Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalMilliseconds
    }
    $cAll = Get-CpuMs
    # One compiled pass over the mailboxes tree feeds the monitor, both zone
    # walks and (indirectly) the busy pre-check. Consolidation, not raw speed:
    # the old sweep paid ~10 separate cmdlet recursions plus 12+ directory
    # probes and one Get-ChildItem per agent zone; now it is one walk.
    $scan = Get-MailboxScan
    Invoke-MonitorInflight -Scan $scan
    $tMonitor = [int]((Get-CpuMs) - $cAll); $cStage = Get-CpuMs
    foreach ($a in (Get-RegisteredAgents)) {
        $agentDir = Join-Path $script:DirMailboxes ([string]$a.name)
        $recipientPull = [string]::IsNullOrWhiteSpace([string]$a.wake) -or ([string]$a.wake -match 'TODO')

        # .NET enumeration: Get-ChildItem cmdlet overhead x agents x zones
        # measured ~2s CPU per sweep under real-time AV scanning.
        foreach ($zone in @(@('outbox','take'), @('inbox','route'))) {
            $files = Get-ScanZoneFiles -Scan $scan -Agent ([string]$a.name) -Zone $zone[0]
            if (-not $files.Count) { continue }
            # Busy pre-check (route zone only): a route child spawned against a
            # mid-session recipient comes straight back QUEUED-BUSY, so the
            # spawn was pure overhead - one child process per letter per sweep.
            # Lazy (v2.2): only consulted when the zone actually holds mail,
            # and answered from the scan map - zero file stats.
            $busy = ($zone[1] -eq 'route') -and (Test-AgentBusy -AgentDir $agentDir -Scan $scan)
            foreach ($p in $files) {
                $n = [System.IO.Path]::GetFileName($p)
                if ($n -like '*.tmp' -or $n -like '*.part') { continue }
                if ($zone[1] -eq 'route') {
                    if ($n -like 'sys-*' -or $busy) { continue }
                    # PULL recipients: route.ps1 has nothing to do for them
                    # beyond the once-per-letter WARN flag - the letter waits
                    # for the agent's own mail-check by contract. Re-spawning
                    # the child every sweep for a stale backlog (39 letters
                    # observed) burned ~1 child process x letter x sweep for
                    # nothing. Fresh deliveries still ring via the FSW event
                    # path, which is never gated.
                    if ($recipientPull) { continue }
                }
                # Freshness/existence come from the scan, not a re-stat: the
                # scan is at most seconds old and already carries every mtime.
                # A letter newer than the scan is not in $files at all, so the
                # take-bell 15s quiet window holds; a letter claimed after the
                # scan is simply missing - route/claim children own the race
                # via move-as-mutex and exit cleanly on "already claimed or
                # gone".
                $ft = Get-ScanTime -Fp $scan[$p]
                if ($zone[1] -eq 'take' -and $ft -and ((Get-Date) - $ft).TotalSeconds -lt 15) { continue }
                if ($zone[1] -eq 'take') { Invoke-TakeoutSafe -Path $p } else { Invoke-RouteSafe -Path $p }
            }
        }
    }
    # NOTE: "| Out-Null" does NOT silence Write-Host. Write-Host writes to
    # the Information stream (6); Out-Null only drains the success stream.
    # That is why the integrity summary used to scroll past on the console
    # every sweep.
    #
    # We redirect 1> and 6> to $null rather than using "*>": the all-stream
    # form builds a redirection pipeline, and in a console-less process
    # ("conhost --headless") that pipeline can fail with a Win32 console
    # error. Two explicit redirects are safe in both environments.
    $tScans = [int]((Get-CpuMs) - $cStage); $cStage = Get-CpuMs
    try { & (Join-Path $PSScriptRoot 'cleanup.ps1') -Root $script:Root 1> $null 6> $null } catch {
        Write-SystemLog ('cleanup error :: ' + $_.Exception.Message)
    }
    $tCleanup = [int]((Get-CpuMs) - $cStage); $cStage = Get-CpuMs
    try { & (Join-Path $PSScriptRoot 'integrity.ps1') -Root $script:Root 1> $null 6> $null } catch {
        Write-SystemLog ('integrity error :: ' + $_.Exception.Message)
    }
    $tIntegrity = [int]((Get-CpuMs) - $cStage); $cStage = Get-CpuMs
    Update-Dashboard   # keep the panel's data (and its daemon-alive pill) fresh every sweep
    $tDash = [int]((Get-CpuMs) - $cStage)
    Write-SystemLog ('sweep cpu ms: scans=' + $tScans + ' monitor=' + $tMonitor + ' cleanup=' + $tCleanup + ' integrity=' + $tIntegrity + ' dashboard=' + $tDash + ' total=' + [int]((Get-CpuMs) - $cAll))
}

try {
    Invoke-Sweep   # startup sweep: catch anything missed while the daemon was down
} catch {
    # The loop's own sweeps are try/catch'd per call; this first one used to be
    # bare - with ErrorActionPreference=Stop, one transient IO error in a
    # contested startup (requeues racing route children) silently killed the
    # daemon before the main loop ever started, and the app's monitor spawned
    # another one into the same battlefield.
    Write-SystemLog ('startup sweep error :: ' + $_.Exception.Message)
}
# The startup banner goes to the log, not the console: the daemon must stay
# silent no matter which console host it ends up attached to.
Write-SystemLog ('watch running on ' + $script:DirMailboxes)

$deadline = $null
if ($MaxSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($MaxSeconds) }
$lastSweep = Get-Date
$lastBeat = Get-Date
$lastDash = Get-Date
$script:DashDirty = $false
$script:SawEvent = $false

try {
    while ($true) {
        # Heartbeat FIRST, before anything that can block. It proves the pump
        # is alive and turning; a watchdog (or a human asking "is the postman
        # working?") reads this file's mtime instead of guessing from process
        # lists. It must be written before the potentially slow work, so that
        # a stall downstream still leaves evidence that the loop is running.
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 5) {
            try {
                $beat = Join-Path $script:DirLogs 'watch.heartbeat'
                [System.IO.File]::WriteAllText($beat, (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $script:UTF8Bom)
            } catch {}
            $lastBeat = Get-Date
        }

        $ev = Wait-Event -Timeout 3
        if ($ev) {
            while ($ev) {
                $src = $ev.SourceEventArgs
                if ($src -and $src.FullPath) {
                    $p = [string]$src.FullPath
                    if ($p -like '*.md' -and $p -notlike '*.tmp' -and $p -notlike '*.part') {
                        $script:DashDirty = $true   # panel data may be stale
                        if ($p -match '\\inbox\\') {
                            # Fast reconciliation cadence only for real mail
                            # movement. The loop's own processing/sent churn
                            # (claims, monitor stamps) used to pin the sweep at
                            # 120s forever - even with the office idle.
                            $script:SawEvent = $true
                            # sys-* service mails are informational; never auto-route them.
                            if ($p -notmatch '\\sys-[^\\]*\.md$') {
                                Invoke-RouteSafe -Path $p
                                # Doorbell (v2.2): ring hooks on arrival; the
                                # dispatch itself is debounced in the main loop.
                                $ag = Get-AgentFromPath -FilePath $p
                                if ($ag -and $script:DoorbellHooks.ContainsKey($ag)) {
                                    $script:DoorbellPend[$ag] = Get-Date
                                }
                            }
                        } elseif ($p -match '\\outbox\\') {
                            $script:SawEvent = $true
                            # Take bell: the rename <id>.tmp -> <id>.md means content complete.
                            Invoke-TakeoutSafe -Path $p
                        }
                    }
                }
                Remove-Event -EventIdentifier $ev.EventIdentifier
                $ev = Wait-Event -Timeout 1   # drain bursts
            }
        }
        # Event-driven dashboard: mailbox activity (FSW) marks it dirty, and it
        # regenerates at most once a minute. The sweep's own Update-Dashboard
        # remains the fallback for changes outside the watched tree (registry
        # cards, archivals).
        if ($script:DashDirty -and ((Get-Date) - $lastDash).TotalSeconds -ge 60) {
            $script:DashDirty = $false
            $lastDash = Get-Date
            try { Update-Dashboard } catch { Write-SystemLog ('dashboard error :: ' + $_.Exception.Message) }
        }
        # Doorbell dispatch: ~2s debounce after the last inbox event per agent
        # (route delivery lands as .part move + sidecar writes - several events
        # for one letter). Fired detached; never blocks the pump.
        if ($script:DoorbellPend.Count -gt 0) {
            $nowBell = Get-Date
            foreach ($ag in @($script:DoorbellPend.Keys)) {
                if (($nowBell - $script:DoorbellPend[$ag]).TotalSeconds -lt 2) { continue }
                $script:DoorbellPend.Remove($ag)
                try {
                    $inb = Join-Path (Join-Path $script:DirMailboxes $ag) 'inbox'
                    $cnt = 0
                    foreach ($p in [System.IO.Directory]::GetFiles($inb, '*.md')) {
                        $fn = [System.IO.Path]::GetFileName($p)
                        if ($fn -like 'sys-*' -or $fn -like '*.tmp' -or $fn -like '*.part') { continue }
                        $cnt++
                    }
                    Write-Journal -Agent $ag -Action 'POLL' -Detail ('new mail: count=' + $cnt)
                    $cmd = [string]$script:DoorbellHooks[$ag]
                    $cmd = $cmd.Replace('{count}', [string]$cnt).Replace('{agent}', $ag).Replace('{root}', $script:Root)
                    Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /c ' + $cmd) `
                        -WindowStyle Hidden -WorkingDirectory $script:Root | Out-Null
                    Write-SystemLog ('doorbell rung: ' + $ag + ' count=' + $cnt)
                } catch { Write-SystemLog ('doorbell failed: ' + $ag + ' :: ' + $_.Exception.Message) }
            }
        }
        # Adaptive reconciliation cadence: fast while activity is flowing,
        # slow when the office has been quiet since the last sweep.
        $sweepEvery = if ($script:SawEvent) { $SweepSeconds } else { $IdleSeconds }
        if (((Get-Date) - $lastSweep).TotalSeconds -ge $sweepEvery) {
            try { Invoke-Sweep } catch { Write-SystemLog ('sweep error :: ' + $_.Exception.Message) }
            $lastSweep = Get-Date
            $script:SawEvent = $false
        }
        if ($deadline -and (Get-Date) -gt $deadline) { break }
    }
} finally {
    $fsw.EnableRaisingEvents = $false
    $fsw.Dispose()
    foreach ($s in @($sub1, $sub2)) {
        try { Unregister-Event -SubscriptionId $s.Id -ErrorAction SilentlyContinue } catch {}
    }
    if ($script:WatchMutex) {
        try { $script:WatchMutex.ReleaseMutex() } catch {}
        try { $script:WatchMutex.Dispose() } catch {}
    }
    Write-SystemLog 'watch stopped'
}
