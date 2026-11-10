# registry-audit.ps1 - read-only compliance audit of registry cards + channels.
#
# Born from incident t-20261110-w7h2: a webhook channel was registered from a
# session-scoped listener that died with its session, and the channel had
# never actually rung (zero DISPATCH ... via webhook lines in the journal).
# Peer review caught it; this script makes the same checks mechanical.
#
# Checks per card (PROTOCOL section 0, four registration rules):
#   [FAIL] TODO/placeholder residue outside wake; missing liveness;
#          unimplemented channels (a2a/mqtt/im) registered; dead webhook
#          listener (TCP connect refused); missing exec adapter script;
#          missing pull field; pull task absent from Task Scheduler.
#   [WARN] mailto registered without config\smtp.json; registered channel
#          never rang (no "DISPATCH ... via <chan>" in journal); PULL agent
#          with no POLL journal line; pull task LastTaskResult != 0.
#   [OK]   card passes; pull fallback registered and its task alive.
#   [EXEMPT] pull: none - <reason> (owner-reported exemption).
#   [SKIP] infra cards (testbot) - exempt from the pull requirement.
#
# Exit codes: 0 = no FAIL, 1 = any FAIL, 2 = bad root.
# Wording follows the i18n table (config\i18n.<lang>.psd1, keys 'audit.*'),
# English fallback inline - same contract as the other CLIs.

param(
    [string]$Root = '',   # data root; default: MAILBOX_ROOT / walk-up / cwd
    [string]$Agent = ''   # audit a single card by registered name
)
$ErrorActionPreference = 'Continue'

if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        $d = Split-Path $PSScriptRoot -Parent
        while ($d -and -not (Test-Path (Join-Path $d 'registry'))) {
            $parent = Split-Path $d -Parent
            if (-not $parent -or $parent -eq $d) { $d = $null; break }
            $d = $parent
        }
        if ($d) { $Root = $d } else { $Root = (Get-Location).Path }
    }
}
$script:Root = $Root
. (Join-Path $PSScriptRoot 'core\i18n.ps1')

$regDir = Join-Path $Root 'registry'
if (-not (Test-Path -LiteralPath $regDir)) {
    Write-Output (Get-AkText -Key 'audit.badroot' -En 'no registry\ directory under data root: {0}' $Root)
    exit 2
}

function Read-CardFm([string]$Path) {
    # Minimal front-matter reader: 'key: value' lines between the first two
    # '---' lines; '#' comment lines are skipped (cards carry wake notes).
    try { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 } catch { return $null }
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }
    $fm = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Trim() -eq '---') { break }
        if ($l -match '^\s*#' -or $l -notmatch ':') { continue }
        $idx = $l.IndexOf(':')
        $k = $l.Substring(0, $idx).Trim()
        $v = $l.Substring($idx + 1).Trim()
        if ($v -match '^(.*?)\s+#\s*.*$') { $v = $Matches[1].Trim() }   # strip inline comment
        if ($k) { $fm[$k] = $v }
    }
    return $fm
}

function Test-TcpPort([string]$H, [int]$P) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ar = $c.BeginConnect($H, $P, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500)
        $alive = $ok -and $c.Connected
        $c.Close()
        return $alive
    } catch { return $false }
}

function Test-SchTask([string]$Name, [ref]$Result) {
    # Returns 'missing' / 'present' / 'unknown' (non-Windows); $Result.Value
    # carries LastTaskResult when determinable ('' if not parsed).
    $getTask = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if (-not $getTask) { return 'unknown' }
    $st = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $st) { return 'missing' }
    $sti = $st | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    if ($sti) { $Result.Value = [string]$sti.LastTaskResult }
    return 'present'
}

Write-Output ('=== [REGISTRY-AUDIT] root=' + $Root + ' ===')
$cards = Get-ChildItem -LiteralPath $regDir -Filter '*.md' | Sort-Object Name
if (-not $cards -or $cards.Count -eq 0) {
    Write-Output (Get-AkText -Key 'audit.no-cards' -En 'no cards in registry\')
    exit 0
}
$totalFails = 0
$totalWarns = 0

foreach ($card in $cards) {
    $fm = Read-CardFm $card.FullName
    if (-not $fm) { continue }
    $name = if ($fm['name']) { [string]$fm['name'] } else { $card.BaseName }
    if ($Agent -and $name -ne $Agent) { continue }

    $fails = 0
    $warns = 0
    $notes = New-Object System.Collections.Generic.List[string]
    $wake = [string]$fm['wake']
    $isPullPrimary = ($wake -eq '' -or $wake -match 'TODO')
    $isInfra = ($name -eq 'testbot' -or $wake -match 'test-stub')

    # --- 1) TODO residue outside wake + placeholder residue in free fields ---
    foreach ($k in @($fm.Keys)) {
        if ($k -eq 'wake') { continue }
        if ([string]$fm[$k] -match 'TODO') {
            $notes.Add((Get-AkText -Key 'audit.fail-todo' -En 'field <{0}> still contains TODO [FAIL]' $k))
            $fails++
        }
    }
    foreach ($k in @('pull', 'contact', 'capabilities')) {
        if ($fm.ContainsKey($k) -and [string]$fm[$k] -match '<[^<>()]{1,30}>') {
            $notes.Add((Get-AkText -Key 'audit.fail-placeholder' -En 'field <{0}> still contains a placeholder [FAIL]' $k))
            $fails++
        }
    }

    # --- 2) liveness declaration (infra cards exempt - a stub has no session) ---
    if (-not $isInfra -and (-not $fm.ContainsKey('liveness') -or -not [string]$fm['liveness'])) {
        $notes.Add((Get-AkText -Key 'audit.fail-liveness' -En 'missing liveness declaration (card counts as unfinished) [FAIL]'))
        $fails++
    }

    # --- 3) pull fallback (rule 4: mandatory for everyone) ---
    $pull = if ($fm.ContainsKey('pull')) { [string]$fm['pull'] } else { '' }
    if ($isInfra) {
        $notes.Add((Get-AkText -Key 'audit.skip-infra' -En 'infra card - exempt from the pull requirement [SKIP]'))
    } elseif (-not $pull) {
        $notes.Add((Get-AkText -Key 'audit.fail-pull-missing' -En 'missing pull field - poll fallback is mandatory for every agent (PROTOCOL section 0) [FAIL]'))
        $fails++
    } elseif ($pull -match '^none\b') {
        $reason = ''
        if ($pull -match '^none\s*-\s*(.+)$') { $reason = $Matches[1].Trim() }
        $notes.Add((Get-AkText -Key 'audit.exempt' -En 'pull=none exemption ({0}) [EXEMPT]' $reason))
    } elseif ($pull -match 'task=([^\s;]+)') {
        $taskName = $Matches[1]
        $res = ''
        $status = Test-SchTask $taskName ([ref]$res)
        if ($status -eq 'missing') {
            $notes.Add((Get-AkText -Key 'audit.fail-pull-task-missing' -En 'scheduled task registered in pull does not exist: {0} (card does not match reality) [FAIL]' $taskName))
            $fails++
        } elseif ($status -eq 'unknown') {
            $notes.Add((Get-AkText -Key 'audit.warn-noschtasks' -En 'non-Windows host - cannot verify scheduled task {0} [WARN]' $taskName))
            $warns++
        } else {
            $notes.Add((Get-AkText -Key 'audit.pull-ok' -En 'pull fallback alive (task={0}) [OK]' $taskName))
            # LastTaskResult for a poll task: 0 = ran, nothing new; 1 = ran,
            # new mail found + notify fired (both healthy); 267008..267015 =
            # SCHED_S_* info states (ready / running / not-yet-run).
            $resNum = 0
            if ([int]::TryParse($res, [ref]$resNum)) {
                $healthy = ($resNum -eq 0) -or ($resNum -eq 1) -or ($resNum -ge 267008 -and $resNum -le 267015)
                if (-not $healthy) {
                    $notes.Add((Get-AkText -Key 'audit.warn-pull-task-result' -En 'scheduled task {0} exists but last run result is {1} [WARN]' $taskName $res))
                    $warns++
                }
            }
        }
    }

    # --- 4) wake chain: per-channel reality checks ---
    $tokens = @()
    if ($wake) { $tokens = @($wake -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $pushChans = @()
    foreach ($t in $tokens) {
        if ($t -eq 'TODO') { continue }
        $chan = ($t -split '\s+')[0].ToLowerInvariant()
        switch -Regex ($chan) {
            '^(exec)$' {
                if ($t -match '(scripts[\\/][\w\-\.\\\/]+\.ps1)') {
                    $rel = ($Matches[1] -replace '/', '\')
                    if (-not (Test-Path -LiteralPath (Join-Path $Root $rel))) {
                        $notes.Add((Get-AkText -Key 'audit.fail-exec-script-missing' -En 'exec adapter script does not exist: {0} [FAIL]' $rel))
                        $fails++
                    }
                }
            }
            '^(a2a|mqtt|im)$' {
                $notes.Add((Get-AkText -Key 'audit.fail-channel-unimplemented' -En 'channel {0} is not implemented yet - registering a channel the post office cannot ring is a violation [FAIL]' $chan))
                $fails++
            }
            '^webhook$' {
                $pushChans += $chan
                if ($t -match '^webhook\s+(\S+)') {
                    $url = $Matches[1]
                    try {
                        $u = [Uri]$url
                        $p = if ($u.Port -gt 0) { $u.Port } elseif ($u.Scheme -eq 'https') { 443 } else { 80 }
                        if (-not (Test-TcpPort $u.Host $p)) {
                            $notes.Add((Get-AkText -Key 'audit.fail-webhook-dead' -En 'webhook doorbell has no listener: {0}:{1} (a session-scoped listener died or never lived) [FAIL]' $u.Host $p))
                            $fails++
                        }
                    } catch {
                        $notes.Add((Get-AkText -Key 'audit.fail-webhook-badurl' -En 'webhook doorbell URL unparseable: {0} [FAIL]' $url))
                        $fails++
                    }
                }
            }
            '^mailto$' {
                $pushChans += $chan
                if (-not (Test-Path -LiteralPath (Join-Path $Root 'config\smtp.json'))) {
                    $notes.Add((Get-AkText -Key 'audit.warn-mailto-noconfig' -En 'mailto registered but config\smtp.json does not exist [WARN]'))
                    $warns++
                }
            }
            default {
                $notes.Add((Get-AkText -Key 'audit.warn-unknown-channel' -En 'unrecognized channel in wake chain: {0} [WARN]' $chan))
                $warns++
            }
        }
    }

    # --- 5) journal evidence: has the registered channel ever rung? ---
    $journal = Join-Path $Root ("logs\" + $name + "\journal.log")
    $jLines = $null
    if (Test-Path -LiteralPath $journal) {
        $jLines = Get-Content -LiteralPath $journal -ErrorAction SilentlyContinue
    }
    foreach ($chan in $pushChans) {
        $hit = @($jLines | Where-Object { $_ -match ('via ' + [regex]::Escape($chan) + '(\s|$)') })
        if (-not $hit -or $hit.Count -eq 0) {
            $notes.Add((Get-AkText -Key 'audit.warn-never-dispatched' -En 'wake registers {0} but the journal has no "DISPATCH ... via {0}" - it has never actually rung [WARN]' $chan))
            $warns++
        }
    }
    if ($isPullPrimary -and -not $isInfra) {
        $pollHits = @($jLines | Where-Object { $_ -match '\|\s*POLL\s+\|' })
        if (-not $pollHits -or $pollHits.Count -eq 0) {
            $notes.Add((Get-AkText -Key 'audit.warn-no-poll-journal' -En 'PULL mode but the journal has no POLL line - is the fallback actually running? [WARN]'))
            $warns++
        }
    }

    $totalFails += $fails
    $totalWarns += $warns
    $tag = if ($fails -gt 0) { 'FAIL' } elseif ($warns -gt 0) { 'WARN' } else { 'OK' }
    Write-Output ("{0}:" -f $name)
    foreach ($n in $notes) { Write-Output ("  " + $n) }
    if ($notes.Count -eq 0) {
        Write-Output ("  " + (Get-AkText -Key 'audit.ok' -En 'card passes all checks [OK]'))
    }
    Write-Output ("  -> $tag (fail=$fails warn=$warns)")
}

Write-Output ('---')
Write-Output (Get-AkText -Key 'audit.summary' -En 'audit done: {0} fail(s), {1} warn(s) across audited cards' $totalFails $totalWarns)
if ($totalFails -gt 0) { exit 1 } else { exit 0 }
