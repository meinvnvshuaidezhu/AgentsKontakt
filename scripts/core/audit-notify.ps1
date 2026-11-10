# audit-notify.ps1 - audit findings -> per-agent AUDIT sys mail (lifecycle-managed).
#
# The post office tells an agent when ITS OWN card/channel is out of
# compliance (registry-audit FAIL/WARN), so the agent can self-fix instead of
# the owner relaying by hand (born from t-20261110-w7h2 and the workbuddy
# pull-missing case it surfaced).
#
# Letter lifecycle (owner rules, 2026-11-11):
#   KEEP      the letter stays in the inbox until the fix is confirmed - it
#             is EXEMPT from sys_retention_days purging (cleanup.ps1 skips
#             mails tracked in this ledger). No change in findings -> the
#             letter is left untouched (no re-send).
#   RESEND    only when the fix requirements change (a NEW finding key
#             appears): the old letter is deleted and a fresh one listing the
#             FULL current finding set is sent. Keys that healed in the same
#             round are cleared from the ledger but do NOT trigger a resend.
#   WITHDRAW  when every key of an agent is healed - which also covers
#             DEREGISTRATION (no card -> no findings) - the ledger is cleared
#             and the letter is removed. No "fixed" receipt is ever sent.
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

    # ---- healed keys: in ledger, gone from the current audit ----
    # agent -> current letter mail, captured BEFORE heal-clear: a fully
    # healed agent has no remaining ledger keys and must still be withdrawn.
    $ledgerAgents = @{}
    foreach ($kv in $ledger.GetEnumerator()) {
        $a = ($kv.Key -split '\|', 2)[0]
        if (-not $ledgerAgents.ContainsKey($a)) { $ledgerAgents[$a] = [string]$kv.Value.mail }
    }
    $healed = @($ledger.Keys | Where-Object { -not $current.ContainsKey($_) })
    foreach ($k in $healed) { $ledger.Remove($k) | Out-Null }

    # ---- withdraw letters of fully-healed agents (covers deregistration) ----
    foreach ($a in $ledgerAgents.Keys) {
        $stillOpen = @($ledger.Keys | Where-Object { ($_ -split '\|', 2)[0] -eq $a })
        if ($stillOpen.Count -gt 0 -or -not $ledgerAgents[$a]) { continue }
        $oldPath = Join-Path (Join-Path $script:DirMailboxes $a) ('inbox\' + $ledgerAgents[$a])
        if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
            Write-Journal -Agent $a -Action 'AUDIT' -Detail ('cleared mail removed=' + $ledgerAgents[$a])
        }
    }
    if ($healed.Count -gt 0) { Write-SystemLog ('audit-notify: cleared ' + $healed.Count + ' healed key(s)') }

    # ---- per agent: KEEP (no change) / RESEND (new finding key) / SEND (first) ----
    $currentAgents = @{}
    foreach ($kv in $current.GetEnumerator()) {
        $a = ($kv.Key -split '\|', 2)[0]
        if (-not $currentAgents.ContainsKey($a)) { $currentAgents[$a] = New-Object System.Collections.Generic.List[object] }
        $currentAgents[$a].Add($kv.Value)
    }

    $intervalMin = [int]([double]((Get-SystemConfig)['audit_notify_minutes']))
    $sent = 0
    $resent = 0
    foreach ($agent in $currentAgents.Keys) {
        $items = $currentAgents[$agent]
        $ledgerKeys = @($ledger.Keys | Where-Object { ($_ -split '\|', 2)[0] -eq $agent } | ForEach-Object { ($_ -split '\|', 2)[1] })
        $newItems = @($items | Where-Object { $ledgerKeys -notcontains $_.key })
        if ($newItems.Count -eq 0) { continue }   # unchanged -> the letter stays untouched

        # fix requirements updated: withdraw the old letter, send a fresh one
        # listing the FULL current finding set
        $oldMail = $null
        foreach ($k in $ledgerKeys) {
            $e = $ledger[($agent + '|' + $k)]
            if ($e -and [string]$e.mail) { $oldMail = [string]$e.mail; break }
        }
        if ($oldMail) {
            $oldPath = Join-Path (Join-Path $script:DirMailboxes $agent) ('inbox\' + $oldMail)
            if (Test-Path -LiteralPath $oldPath) { Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue }
        }

        try {
            $block = ($items | ForEach-Object {
                $fmtArgs = @($_.args)
                '- [' + $_.level + '] ' + (Get-AkText -Key ('audit.' + $_.key) -En ([string]$AuditEnTemplates[$_.key]) @fmtArgs)
            }) -join "`r`n"
            $body = ((Get-AkLines 'audit-notify.body' `
                'The registry audit found issues with your card/channel. Please self-fix. This mail is read-only - no reply needed:', `
                '', `
                '{0}', `
                '', `
                'Fix guide: docs\Agent操作指引.md section 2.6 (PULL fallback in five steps) and PROTOCOL section 0 (channel registration rules).', `
                'This mail is kept until the fix is confirmed (exempt from expiry); when new fix requirements appear it is replaced by a fresh one; once everything passes it is withdrawn automatically.', `
                'Audit cadence: about every {1} minutes    Data root: {2}') |
                ForEach-Object { $_ -f $block, $intervalMin, $script:Root }) -join "`r`n"
            $mail = Write-SystemMail -To $agent -Topic ('t-audit-' + (Get-Date -Format 'yyyyMMdd')) -Subject ('AUDIT ' + $agent) -Body $body
            # one explicit dispatch: sys mails are never auto-routed by the watcher
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'route.ps1') -File $mail -Root $script:Root 2>&1
            $mailName = Split-Path $mail -Leaf
            $action = if ($oldMail) { 'resend' } else { 'notify' }
            Write-Journal -Agent $agent -Action 'AUDIT' -Detail ($action + ' keys=' + (($items | ForEach-Object { $_.key }) -join ',') + ' mail=' + $mailName + $(if ($oldMail) { ' replaced=' + $oldMail }))
            $nowStamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
            foreach ($n in $items) {
                $prev = $ledger[($agent + '|' + $n.key)]
                $seen = if ($prev -and [string]$prev.first_seen) { [string]$prev.first_seen } else { $nowStamp }
                $ledger[($agent + '|' + $n.key)] = [pscustomobject]@{
                    level      = $n.level
                    first_seen = $seen
                    mail       = $mailName
                }
            }
            if ($oldMail) { $resent++ } else { $sent++ }
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
    Write-SystemLog ('audit-notify: done (sent=' + $sent + ' resent=' + $resent + ' ledger keys=' + $ledger.Count + ' healed=' + $healed.Count + ')')
    exit 0
} catch {
    Write-SystemLog ('audit-notify: internal error: ' + $_.Exception.Message)
    exit 1
}
