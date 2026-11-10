# registry-audit.ps1 - read-only compliance audit of registry cards + channels.
#
# Born from incident t-20261110-w7h2: a webhook channel was registered from a
# session-scoped listener that died with its session, and the channel had
# never actually rung (zero DISPATCH ... via webhook lines in the journal).
# Peer review caught it; this script makes the same checks mechanical.
#
# This file is the CLI RENDERER: it prints the per-card report and maps the
# result to exit codes. The check logic itself lives in core\audit-lib.ps1
# (shared with core\audit-notify.ps1, which turns findings into per-agent
# AUDIT sys mails with a strictly-once ledger). Wording follows the i18n
# table (config\i18n.<lang>.psd1, keys 'audit.*'), English fallback templates
# in $AuditEnTemplates - same contract as the other CLIs.
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
# -Notify: after rendering, run core\audit-notify.ps1 against the same root
# (per-agent AUDIT sys mail, strictly once per finding). Owner-facing manual
# trigger; the watch loop runs audit-notify on its own cadence.

param(
    [string]$Root = '',   # data root; default: MAILBOX_ROOT / walk-up / cwd
    [string]$Agent = '',  # audit a single card by registered name
    [switch]$Notify       # also run the notify pipeline (send sys mails)
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
. (Join-Path $PSScriptRoot 'core\audit-lib.ps1')

$regDir = Join-Path $Root 'registry'
if (-not (Test-Path -LiteralPath $regDir)) {
    Write-Output (Get-AkText -Key 'audit.badroot' -En $AuditEnTemplates['badroot'] $Root)
    exit 2
}

Write-Output ('=== [REGISTRY-AUDIT] root=' + $Root + ' ===')
$cardFiles = @(Get-ChildItem -LiteralPath $regDir -Filter '*.md' -ErrorAction SilentlyContinue)
if (-not $cardFiles -or $cardFiles.Count -eq 0) {
    Write-Output (Get-AkText -Key 'audit.no-cards' -En $AuditEnTemplates['no-cards'])
    exit 0
}

$results = Get-AuditFindings -Root $Root -Agent $Agent
$totalFails = 0
$totalWarns = 0

foreach ($r in $results) {
    $fails = @($r.notes | Where-Object { $_.level -eq 'FAIL' }).Count
    $warns = @($r.notes | Where-Object { $_.level -eq 'WARN' }).Count
    $totalFails += $fails
    $totalWarns += $warns
    $tag = if ($fails -gt 0) { 'FAIL' } elseif ($warns -gt 0) { 'WARN' } else { 'OK' }
    Write-Output ("{0}:" -f $r.agent)
    foreach ($n in $r.notes) {
        $fmtArgs = @($n.args)
        Write-Output ('  ' + (Get-AkText -Key ('audit.' + $n.key) -En ([string]$AuditEnTemplates[$n.key]) @fmtArgs))
    }
    if ($r.notes.Count -eq 0) {
        Write-Output ('  ' + (Get-AkText -Key 'audit.ok' -En $AuditEnTemplates['ok']))
    }
    Write-Output ("  -> $tag (fail=$fails warn=$warns)")
}

Write-Output ('---')
Write-Output (Get-AkText -Key 'audit.summary' -En $AuditEnTemplates['summary'] $totalFails $totalWarns)

if ($Notify) {
    # Manual trigger surface: same pipeline the watch loop runs on its cadence.
    & (Join-Path $PSScriptRoot 'core\audit-notify.ps1') -Root $Root
}

if ($totalFails -gt 0) { exit 1 } else { exit 0 }
