# audit-lib.ps1 - registry-card compliance checks as a reusable library.
#
# Consumers:
#   scripts\registry-audit.ps1  - CLI renderer (console report + exit codes)
#   scripts\core\audit-notify.ps1 - findings -> per-agent AUDIT sys mail
#
# Dependency-free on purpose (does not dot-source common.ps1): takes $Root
# explicitly and reads cards/journals directly, so the CLI keeps working
# standalone. Findings carry i18n KEY SUFFIXES ('fail-pull-missing') plus
# format args; consumers render via config\i18n.<lang>.psd1 key 'audit.<key>'
# with $AuditEnTemplates as the shared English fallback. $ErrorActionPreference
# is NOT set here - each consumer enforces its own.

$AuditEnTemplates = @{
    'badroot'                    = 'no registry\ directory under data root: {0}'
    'no-cards'                   = 'no cards in registry\'
    'fail-todo'                  = 'field <{0}> still contains TODO [FAIL]'
    'fail-placeholder'           = 'field <{0}> still contains a placeholder [FAIL]'
    'fail-liveness'              = 'missing liveness declaration (card counts as unfinished) [FAIL]'
    'fail-pull-missing'          = 'missing pull field - poll fallback is mandatory for every agent (PROTOCOL section 0) [FAIL]'
    'fail-pull-task-missing'     = 'scheduled task registered in pull does not exist: {0} (card does not match reality) [FAIL]'
    'fail-channel-unimplemented' = 'channel {0} is not implemented yet - registering a channel the post office cannot ring is a violation [FAIL]'
    'fail-webhook-dead'          = 'webhook doorbell has no listener: {0}:{1} (a session-scoped listener died or never lived) [FAIL]'
    'fail-webhook-badurl'        = 'webhook doorbell URL unparseable: {0} [FAIL]'
    'fail-exec-script-missing'   = 'exec adapter script does not exist: {0} [FAIL]'
    'warn-mailto-noconfig'       = 'mailto registered but config\smtp.json does not exist [WARN]'
    'warn-never-dispatched'      = 'wake registers {0} but the journal has no "DISPATCH ... via {0}" - it has never actually rung [WARN]'
    'warn-no-poll-journal'       = 'PULL mode but the journal has no POLL line - is the fallback actually running? [WARN]'
    'warn-pull-task-result'      = 'scheduled task {0} exists but last run result is {1} [WARN]'
    'warn-noschtasks'            = 'non-Windows host - cannot verify scheduled task {0} [WARN]'
    'warn-unknown-channel'       = 'unrecognized channel in wake chain: {0} [WARN]'
    'exempt'                     = 'pull=none exemption ({0}) [EXEMPT]'
    'skip-infra'                 = 'infra card - exempt from the pull requirement [SKIP]'
    'pull-ok'                    = 'pull fallback alive (task={0}) [OK]'
    'ok'                         = 'card passes all checks [OK]'
    'summary'                    = 'audit done: {0} fail(s), {1} warn(s) across audited cards'
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

function Get-AuditFindings {
    # Structured audit of every registry card under $Root. Returns a list of
    # per-card results in the exact order the CLI renders them:
    #   [pscustomobject]@{ agent = <name>; notes = @([pscustomobject]@{
    #       key = <i18n suffix like 'fail-pull-missing'>;
    #       level = 'FAIL'|'WARN'|'NOTE';
    #       args = @(<format args for the 'audit.<key>' template>) }) }
    # 'NOTE' covers the neutral lines (skip-infra / exempt / pull-ok) that
    # neither count nor colour the tag. A card with zero notes renders the
    # 'audit.ok' line. Cards with unreadable front-matter are skipped (same
    # as the original inline implementation).
    param([string]$Root, [string]$Agent = '')
    $out = New-Object System.Collections.Generic.List[object]
    $regDir = Join-Path $Root 'registry'
    if (-not (Test-Path -LiteralPath $regDir)) { return ,$out }
    $cards = Get-ChildItem -LiteralPath $regDir -Filter '*.md' | Sort-Object Name
    if (-not $cards -or $cards.Count -eq 0) { return ,$out }
    foreach ($card in $cards) {
        $fm = Read-CardFm $card.FullName
        if (-not $fm) { continue }
        $name = if ($fm['name']) { [string]$fm['name'] } else { $card.BaseName }
        if ($Agent -and $name -ne $Agent) { continue }

        $notes = New-Object System.Collections.Generic.List[object]
        $wake = [string]$fm['wake']
        $isPullPrimary = ($wake -eq '' -or $wake -match 'TODO')
        $isInfra = ($name -eq 'testbot' -or $wake -match 'test-stub')

        # --- 1) TODO residue outside wake + placeholder residue in free fields ---
        foreach ($k in @($fm.Keys)) {
            if ($k -eq 'wake') { continue }
            if ([string]$fm[$k] -match 'TODO') {
                $notes.Add([pscustomobject]@{ key = 'fail-todo'; level = 'FAIL'; args = @($k) })
            }
        }
        foreach ($k in @('pull', 'contact', 'capabilities')) {
            if ($fm.ContainsKey($k) -and [string]$fm[$k] -match '<[^<>()]{1,30}>') {
                $notes.Add([pscustomobject]@{ key = 'fail-placeholder'; level = 'FAIL'; args = @($k) })
            }
        }

        # --- 2) liveness declaration (infra cards exempt - a stub has no session) ---
        if (-not $isInfra -and (-not $fm.ContainsKey('liveness') -or -not [string]$fm['liveness'])) {
            $notes.Add([pscustomobject]@{ key = 'fail-liveness'; level = 'FAIL'; args = @() })
        }

        # --- 3) pull fallback (rule 4: mandatory for everyone) ---
        $pull = if ($fm.ContainsKey('pull')) { [string]$fm['pull'] } else { '' }
        if ($isInfra) {
            $notes.Add([pscustomobject]@{ key = 'skip-infra'; level = 'NOTE'; args = @() })
        } elseif (-not $pull) {
            $notes.Add([pscustomobject]@{ key = 'fail-pull-missing'; level = 'FAIL'; args = @() })
        } elseif ($pull -match '^none\b') {
            $reason = ''
            if ($pull -match '^none\s*-\s*(.+)$') { $reason = $Matches[1].Trim() }
            $notes.Add([pscustomobject]@{ key = 'exempt'; level = 'NOTE'; args = @($reason) })
        } elseif ($pull -match 'task=([^\s;]+)') {
            $taskName = $Matches[1]
            $res = ''
            $status = Test-SchTask $taskName ([ref]$res)
            if ($status -eq 'missing') {
                $notes.Add([pscustomobject]@{ key = 'fail-pull-task-missing'; level = 'FAIL'; args = @($taskName) })
            } elseif ($status -eq 'unknown') {
                $notes.Add([pscustomobject]@{ key = 'warn-noschtasks'; level = 'WARN'; args = @($taskName) })
            } else {
                $notes.Add([pscustomobject]@{ key = 'pull-ok'; level = 'NOTE'; args = @($taskName) })
                # LastTaskResult for a poll task: 0 = ran, nothing new; 1 = ran,
                # new mail found + notify fired (both healthy); 267008..267015 =
                # SCHED_S_* info states (ready / running / not-yet-run).
                $resNum = 0
                if ([int]::TryParse($res, [ref]$resNum)) {
                    $healthy = ($resNum -eq 0) -or ($resNum -eq 1) -or ($resNum -ge 267008 -and $resNum -le 267015)
                    if (-not $healthy) {
                        $notes.Add([pscustomobject]@{ key = 'warn-pull-task-result'; level = 'WARN'; args = @($taskName, $res) })
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
                            $notes.Add([pscustomobject]@{ key = 'fail-exec-script-missing'; level = 'FAIL'; args = @($rel) })
                        }
                    }
                }
                '^(a2a|mqtt|im)$' {
                    $notes.Add([pscustomobject]@{ key = 'fail-channel-unimplemented'; level = 'FAIL'; args = @($chan) })
                }
                '^webhook$' {
                    $pushChans += $chan
                    if ($t -match '^webhook\s+(\S+)') {
                        $url = $Matches[1]
                        try {
                            $u = [Uri]$url
                            $p = if ($u.Port -gt 0) { $u.Port } elseif ($u.Scheme -eq 'https') { 443 } else { 80 }
                            if (-not (Test-TcpPort $u.Host $p)) {
                                $notes.Add([pscustomobject]@{ key = 'fail-webhook-dead'; level = 'FAIL'; args = @($u.Host, $p) })
                            }
                        } catch {
                            $notes.Add([pscustomobject]@{ key = 'fail-webhook-badurl'; level = 'FAIL'; args = @($url) })
                        }
                    }
                }
                '^mailto$' {
                    $pushChans += $chan
                    if (-not (Test-Path -LiteralPath (Join-Path $Root 'config\smtp.json'))) {
                        $notes.Add([pscustomobject]@{ key = 'warn-mailto-noconfig'; level = 'WARN'; args = @() })
                    }
                }
                default {
                    $notes.Add([pscustomobject]@{ key = 'warn-unknown-channel'; level = 'WARN'; args = @($chan) })
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
                $notes.Add([pscustomobject]@{ key = 'warn-never-dispatched'; level = 'WARN'; args = @($chan) })
            }
        }
        if ($isPullPrimary -and -not $isInfra) {
            $pollHits = @($jLines | Where-Object { $_ -match '\|\s*POLL\s+\|' })
            if (-not $pollHits -or $pollHits.Count -eq 0) {
                $notes.Add([pscustomobject]@{ key = 'warn-no-poll-journal'; level = 'WARN'; args = @() })
            }
        }

        $out.Add([pscustomobject]@{ agent = $name; notes = $notes })
    }
    return ,$out
}
