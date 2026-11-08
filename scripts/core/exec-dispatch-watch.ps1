<#
exec-dispatch-watch.ps1 - terminal-state watcher for route.ps1's exec channel.

route.ps1 no longer spawns the wake command directly. It spawns THIS script
(detached, hidden), which owns the child process and therefore its exit code,
and records the terminal state in the message's <id>.progress sidecar exactly
as PROTOCOL.md 0.5 item 4 ("terminal last words") requires:

    STATUS ok
    STATUS failed code=<n> reason=<...>

route.ps1 polls that sidecar for a bounded grace period (route -ExecProbeMs)
right after starting this script. A non-zero STATUS inside that window means
the wake command died on launch (missing CLI, bad path, crash); the post office
then degrades to the next channel or requeues the mail instead of recording a
DISPATCH that never happened. A wake command still alive after the grace period
is left alone - this script writes its STATUS whenever the real session ends,
minutes or hours later, so route never waits for a long session.

Only route.ps1 calls this script. -Payload is a base64-encoded UTF-8 JSON blob
(cmdLine/progress/agent/messageId/root/log). Base64 survives the argv boundary
untouched, so command lines (which embed prompts with spaces and quotes) and
paths need no re-quoting.

Manual use: build the payload with route.ps1's helper or:
    $j = '{"cmdLine":"exit 0","progress":"C:\\tmp\\x.progress","messageId":"x","root":"C:\\tmp","log":"C:\\tmp\\d.log"}'
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($j))
    powershell -NoProfile -File scripts\exec-dispatch-watch.ps1 -Payload $b
#>
param(
    [Parameter(Mandatory = $true)][string]$Payload
)
$ErrorActionPreference = 'Continue'
$script:Utf8 = New-Object System.Text.UTF8Encoding($true)

function Write-Line {
    param([string]$Path, [string]$Text)
    if (-not $Path) { return }
    try {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { return }
        [System.IO.File]::AppendAllText($Path, $Text + "`r`n", $script:Utf8)
    } catch { }
}

function Resolve-ProgressPath {
    # The sidecar normally sits next to the processing message. Once the
    # handling session replied, send.ps1 archives message+sidecar together, so
    # the terminal line travels to the archive copy instead; look there before
    # falling back to the dispatch log only.
    param([string]$Preferred, [string]$MessageId, [string]$Root)
    if ($Preferred -and (Test-Path -LiteralPath $Preferred -PathType Leaf)) { return $Preferred }
    if (-not $MessageId) { return '' }
    $name = $MessageId + '.progress'
    foreach ($base in @((Join-Path $Root 'mailboxes'), (Join-Path $Root 'archive'))) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $hit = Get-ChildItem -LiteralPath $base -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

$cfg = $null
try {
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
    $cfg = $json | ConvertFrom-Json
} catch { }

if (-not $cfg -or [string]::IsNullOrWhiteSpace([string]$cfg.cmdLine)) {
    Write-Line -Path ([string]$cfg.log) -Text ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] watcher: unusable payload (no command line)')
    exit 0
}

$mid = [string]$cfg.messageId
$started = Get-Date
$code = -1
$childPid = 0
$err = ''
try {
    # Same launch shape route.ps1 used before: hidden, root as working dir, so
    # wake commands may keep using root-relative paths.
    $child = Start-Process -FilePath 'powershell' -WindowStyle Hidden -WorkingDirectory ([string]$cfg.root) -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', [string]$cfg.cmdLine)
    if ($child) {
        $childPid = $child.Id
        $child.WaitForExit()
        $code = $child.ExitCode
    } else {
        $err = 'Start-Process returned no process handle'
    }
} catch {
    $err = $_.Exception.Message
}
$seconds = [int]((Get-Date) - $started).TotalSeconds

if ($err) {
    $status = 'STATUS failed code=-1 reason=' + ($err -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
} elseif ($code -eq 0) {
    $status = 'STATUS ok'
} else {
    $status = 'STATUS failed code=' + $code + ' reason=exec wake exited non-zero after ' + $seconds + 's'
}

$target = Resolve-ProgressPath -Preferred ([string]$cfg.progress) -MessageId $mid -Root ([string]$cfg.root)
if ($target) { Write-Line -Path $target -Text $status }
$cmdEcho = [string]$cfg.cmdLine
if ($cmdEcho.Length -gt 200) { $cmdEcho = $cmdEcho.Substring(0, 200) + '...' }
Write-Line -Path ([string]$cfg.log) -Text ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $mid + ' pid=' + $childPid + ' exit=' + $code + ' seconds=' + $seconds + ' cmdlen=' + ([string]$cfg.cmdLine).Length + ' cmd="' + $cmdEcho + '" | ' + $status)
exit 0
