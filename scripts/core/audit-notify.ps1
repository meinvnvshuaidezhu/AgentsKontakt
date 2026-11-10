# audit-notify.ps1 - audit findings -> per-agent AUDIT sys mail (deduped).
#
# The post office tells an agent when ITS OWN card/channel is out of
# compliance (registry-audit FAIL/WARN), so the agent can self-fix instead of
# the owner relaying by hand (born from t-20261110-w7h2 and the workbuddy
# pull-missing case it surfaced).
#
# Dedup is STRICTLY once per agent+finding-key (owner decision 2026-11-11):
# the ledger post\audit-notify.json records every notified key; a key already
# present is skipped - the agent is expected to be working on it. When a
# later audit no longer reports the key, the entry is cleared (journal
# 'AUDIT cleared') so a future recurrence notifies again. Known limitation:
# a sys mail expires with sys_retention_days - an agent that never checks
# its inbox inside that window will not see this reminder (no re-send).
#
# Delivery: Write-SystemMail (inbox copy; sys-* is never auto-routed) plus
# ONE explicit route dispatch so PUSH agents are woken at once - the same
# pattern as the stall report. If every channel is dead (often the very
# finding being reported) the dispatch simply fails its wake chain and the
# inbox copy waits for the agent's next mail-check.
#
# Run by the watch loop on its audit_notify_minutes cadence (detached child,
# see watch.ps1) and manually via registry-audit.ps1 -Notify.
# Exit codes: 0 = ran fine (findings or not), 1 = internal error.

param([string]$Root = '')
$ErrorActionPreference = 'Continue'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        # the script sits in core\ - walk up to the data root (a dir holding registry\)
        $d = $PSScriptRoot
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if ($d) { $Root = $d } elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
        else { $Root = (Get-Location).Path }
    }
}
. (Join-Path $PSScriptRoot 'common.ps1')      # contract: $Root set before dot-sourcing
. (Join-Path $PSScriptRoot 'audit-lib.ps1')

try {
    $results = Get-AuditFindings -Root $script:Root

    # ---- ledger: "<agent>|<key>" -> { level; first_seen; mail } ----
    $ledgerPath = Join-Path $script:DirPost 'audit-notify.json'
    $ledger = @{}
    if (Test-Path -LiteralPath $ledgerPath) {
        try {
            $raw = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pr in $raw.PSObject.Properties) { $ledger[$pr.Name] = $pr.Value }
        } catch {
            Write-SystemLog ('audit-notify: ledger unreadable, starting clean: ' + $_.Exception.Message)
        }
    }

    # ---- current actionable findings (FAIL/WARN only; NOTE lines are cosmetic) ----
    $current = @{}
    foreach ($r in $results) {
        foreach ($n in $r.notes) {
            if ($n.level -eq 'FAIL' -or $n.level -eq 'WARN') {
                $current[($r.agent + '|' + $n.key)] = $n
            }
        }
    }

    # ---- clear healed keys: finding gone -> ledger entry gone (recurrence re-notifies) ----
    $healed = @($ledger.Keys | Where-Object { -not $current.ContainsKey($_) })
    foreach ($k in $healed) {
        $agent = ($k -split '\|', 2)[0]
        Write-Journal -Agent $agent -Action 'AUDIT' -Detail ('cleared key=' + $k)
        $ledger.Remove($k) | Out-Null
    }
    if ($healed.Count -gt 0) { Write-SystemLog ('audit-notify: cleared ' + $healed.Count + ' healed key(s)') }

    # ---- group NOT-yet-notified findings per agent (strictly-once dedup) ----
    $byAgent = @{}
    foreach ($kv in $current.GetEnumerator()) {
        if ($ledger.ContainsKey($kv.Key)) { continue }   # already sent - skip and wait for the agent
        $agent = ($kv.Key -split '\|', 2)[0]
        if (-not $byAgent.ContainsKey($agent)) { $byAgent[$agent] = New-Object System.Collections.Generic.List[object] }
        $byAgent[$agent].Add($kv.Value)
    }

    $intervalMin = [int]([double]((Get-SystemConfig)['audit_notify_minutes']))
    $sent = 0
    foreach ($agent in $byAgent.Keys) {
        try {
            $block = ($byAgent[$agent] | ForEach-Object {
                $fmtArgs = @($_.args)
                '- [' + $_.level + '] ' + (Get-AkText -Key ('audit.' + $_.key) -En ([string]$AuditEnTemplates[$_.key]) @fmtArgs)
            }) -join "`r`n"
            $body = ((Get-AkLines 'audit-notify.body' `
                'The registry audit found issues with your card/channel. Please self-fix. This mail is read-only - no reply needed:', `
                '', `
                '{0}', `
                '', `
                'Fix guide: docs\Agent操作指引.md section 2.6 (PULL fallback in five steps) and PROTOCOL section 0 (channel registration rules).', `
                'This is sent strictly once per finding; the next audit round clears the ledger once it passes (no fixed receipt).', `
                'Audit cadence: about every {1} minutes    Data root: {2}') |
                ForEach-Object { $_ -f $block, $intervalMin, $script:Root }) -join "`r`n"
            $mail = Write-SystemMail -To $agent -Topic ('t-audit-' + (Get-Date -Format 'yyyyMMdd')) -Subject ('AUDIT ' + $agent) -Body $body
            # one explicit dispatch: sys mails are never auto-routed by the watcher
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'route.ps1') -File $mail -Root $script:Root 2>&1
            $mailName = Split-Path $mail -Leaf
            Write-Journal -Agent $agent -Action 'AUDIT' -Detail ('notify keys=' + (($byAgent[$agent] | ForEach-Object { $_.key }) -join ',') + ' mail=' + $mailName)
            foreach ($n in $byAgent[$agent]) {
                $ledger[($agent + '|' + $n.key)] = [pscustomobject]@{
                    level      = $n.level
                    first_seen = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
                    mail       = $mailName
                }
            }
            $sent++
        } catch {
            # no ledger entry on failure: the next round retries this agent
            Write-SystemLog ('audit-notify: mail to ' + $agent + ' failed: ' + $_.Exception.Message)
        }
    }

    # ---- persist the ledger (ConvertTo-Json, no BOM - same convention as meta.json) ----
    if (-not (Test-Path -LiteralPath $script:DirPost)) { New-Item -ItemType Directory -Path $script:DirPost -Force | Out-Null }
    $out = [ordered]@{}
    foreach ($kv in ($ledger.GetEnumerator() | Sort-Object Name)) { $out[$kv.Key] = $kv.Value }
    [System.IO.File]::WriteAllText($ledgerPath, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-SystemLog ('audit-notify: done (agents notified=' + $sent + ', ledger keys=' + $ledger.Count + ', healed=' + $healed.Count + ')')
    exit 0
} catch {
    Write-SystemLog ('audit-notify: internal error: ' + $_.Exception.Message)
    exit 1
}
