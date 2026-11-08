# common.ps1 - shared library for the cross-agent mailbox system.
# Contract: caller sets $Root before dot-sourcing this file.
# Script files stay ASCII on purpose; Chinese text lives in data files
# (templates, docs, html, and now config\i18n.<lang>.psd1 for console text -
# loaded by core\i18n.ps1 below) so Windows PowerShell 5.1 parses scripts safely.

if (-not $Root) { throw 'common.ps1: caller must set $Root before dot-sourcing.' }

# Canonicalize to long-path form: 8.3 short-name components (TEMP dirs,
# cygwin passthrough) would break the textual folder checks downstream.
$Root = (Get-Item -LiteralPath $Root).FullName

$script:Root         = $Root
$script:UTF8Bom     = New-Object System.Text.UTF8Encoding($true)   # v2.3.8: every text file self-declares UTF-8 via BOM
$script:DirRegistry  = Join-Path $Root 'registry'
$script:DirMailboxes = Join-Path $Root 'mailboxes'
$script:DirArchive   = Join-Path $Root 'archive'
$script:DirLogs      = Join-Path $Root 'logs'
$script:DirTemplates = Join-Path $Root 'templates'
$script:DirRouted    = Join-Path $Root 'logs\routed'
$script:DirPost      = Join-Path $Root 'post'
$script:DirManifest  = Join-Path $Root 'post\manifest'
$script:DirCold      = Join-Path $Root 'post\cold'

# Locale layer for console/mail-display text (templates in config\i18n.<lang>.psd1).
. (Join-Path $PSScriptRoot 'i18n.ps1')

function Initialize-Tree {
    foreach ($d in @($script:DirRegistry, $script:DirMailboxes, $script:DirArchive,
                     $script:DirLogs, $script:DirTemplates, $script:DirRouted,
                     $script:DirManifest, $script:DirCold)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $script:UTF8Bom)
}

function Read-FrontMatter {
    param([string]$Path)
    $fm = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $fm }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -match '(?s)\A---\r?\n(.*?)\r?\n---\s*(\r?\n|$)') {
        foreach ($line in ($Matches[1] -split '\r?\n')) {
            if ($line -match '^\s*([A-Za-z0-9_\-]+)\s*:\s*(.*?)\s*$') {
                $k = $Matches[1].ToLower()
                $v = $Matches[2]
                if ($v.StartsWith('[') -and $v.EndsWith(']')) {
                    $inner = $v.Substring(1, $v.Length - 2)
                    $items = @()
                    foreach ($p in ($inner -split ',')) {
                        $t = $p.Trim().Trim("'").Trim('"')
                        if ($t) { $items += $t }
                    }
                    $v = $items
                } else {
                    $v = $v.Trim("'").Trim('"')
                }
                $fm[$k] = $v
            }
        }
    }
    return $fm
}

function Get-RegisteredAgents {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:DirRegistry)) { return ,$list }
    # Process-level memo (v2.2): the watch sweep calls this three times per
    # pass (monitor, route pre-check, dashboard) and every miss re-parsed all
    # registry cards. The TTL is the primary gate - a hit within 5s returns
    # without touching the disk. Card writes go through Update-RegistryField,
    # which invalidates the cache outright, so same-process read-after-write
    # stays correct.
    if ($null -eq $global:AKRegCache) { $global:AKRegCache = @{ list = @(); at = [datetime]::MinValue } }
    if ($global:AKRegCache.at -ne [datetime]::MinValue -and
        ((Get-Date) - $global:AKRegCache.at).TotalSeconds -lt 5) {
        return ,$global:AKRegCache.list
    }
    $cards = @()
    try { $cards = [System.IO.Directory]::GetFiles($script:DirRegistry, '*.md') } catch {}
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $cards) {
        try {
            $fi = New-Object System.IO.FileInfo($p)
            if (-not $fi.Exists) { continue }
            [void]$sb.Append($fi.Name).Append(':').Append($fi.Length).Append(':').Append($fi.LastWriteTimeUtc.Ticks).Append(';')
        } catch {}
    }
    $fp = $sb.ToString()
    if ($global:AKRegCache.fp -eq $fp) {
        $global:AKRegCache.at = Get-Date
        return ,$global:AKRegCache.list
    }
    foreach ($f in $cards) {
        $fm = Read-FrontMatter -Path $f
        if ($fm.ContainsKey('name') -and $fm.ContainsKey('inbox')) {
            $wake = ''
            if ($fm.ContainsKey('wake')) { $wake = [string]$fm['wake'] }
            $owner = ''
            if ($fm.ContainsKey('owner')) { $owner = [string]$fm['owner'] }
            $seen = ''
            if ($fm.ContainsKey('last_seen')) { $seen = [string]$fm['last_seen'] }
            $contact = ''
            if ($fm.ContainsKey('contact')) { $contact = [string]$fm['contact'] }
            $avatar = ''
            if ($fm.ContainsKey('avatar')) { $avatar = [string]$fm['avatar'] }
            $live = ''
            if ($fm.ContainsKey('liveness')) { $live = [string]$fm['liveness'] }
            $stall = 30
            if ($fm.ContainsKey('stall_after') -and ([string]$fm['stall_after']) -match '^\d+$') { $stall = [int]([string]$fm['stall_after']) }
            $list += [pscustomobject]@{
                name  = [string]$fm['name']
                inbox = [string]$fm['inbox']
                wake  = $wake
                owner = $owner
                last_seen = $seen
                contact = $contact
                avatar = $avatar
                liveness = $live
                stall_after = $stall
            }
        }
    }
    $global:AKRegCache.fp = $fp
    $global:AKRegCache.list = $list
    $global:AKRegCache.at = Get-Date
    return ,$list
}

function Ensure-AkScan {
    # One-call guard for the compiled tree scanner. Kept out of the dot-source
    # path on purpose: short-lived child scripts (route/send) must not pay the
    # one-time Add-Type compile for a scanner they never use.
    if ('AkScan' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class AkScan {
    // One line per file: "<path>\t<length>\t<lastWriteUtcTicks>"
    public static string Tree(string root) {
        StringBuilder sb = new StringBuilder(65536);
        Walk(sb, root);
        return sb.ToString();
    }
    // Fingerprint "len:ticks;" per file under each root; summary.md and
    // tmp/part/bak excluded (same exclusion rule as the PS walk it replaced).
    // Directory-mtime gating is deliberately NOT used: status-sidecar rewrites
    // change file content without touching the parent dir's mtime.
    public static string Fingerprint(string[] roots) {
        StringBuilder sb = new StringBuilder(65536);
        foreach (string root in roots) {
            if (root == null || !Directory.Exists(root)) continue;
            AppendFp(sb, root);
        }
        return sb.ToString();
    }
    static void Walk(StringBuilder sb, string dir) {
        try {
            foreach (string f in Directory.EnumerateFiles(dir)) {
                FileInfo fi = null;
                try { fi = new FileInfo(f); } catch {}
                if (fi == null || !fi.Exists) continue;
                sb.Append(f).Append('\t').Append(fi.Length).Append('\t').Append(fi.LastWriteTimeUtc.Ticks).Append('\n');
            }
        } catch {}
        try { foreach (string d in Directory.EnumerateDirectories(dir)) Walk(sb, d); } catch {}
    }
    static void AppendFp(StringBuilder sb, string dir) {
        try {
            foreach (string f in Directory.EnumerateFiles(dir)) {
                string n = Path.GetFileName(f);
                if (n == "summary.md" || n.EndsWith(".tmp") || n.EndsWith(".part") || n.EndsWith(".bak")) continue;
                FileInfo fi = null;
                try { fi = new FileInfo(f); } catch {}
                if (fi == null || !fi.Exists) continue;
                sb.Append(fi.Length).Append(':').Append(fi.LastWriteTimeUtc.Ticks).Append(';');
            }
        } catch {}
        try { foreach (string d in Directory.EnumerateDirectories(dir)) AppendFp(sb, d); } catch {}
    }
}
'@
}

function Get-MailboxScan {
    # path -> "len:ticks" map of every file under mailboxes\ (one compiled
    # pass). Consumers: monitor sent walk, sweep zone walks, busy pre-check.
    # "len:ticks" matches Get-Fp's format byte-for-byte, so ledger entries and
    # scan values are interchangeable.
    Ensure-AkScan
    $map = @{}
    try {
        foreach ($ln in ([AkScan]::Tree($script:DirMailboxes) -split "`n")) {
            if (-not $ln) { continue }
            $i1 = $ln.IndexOf("`t")
            if ($i1 -lt 0) { continue }
            $i2 = $ln.IndexOf("`t", $i1 + 1)
            if ($i2 -lt 0) { continue }
            $map[$ln.Substring(0, $i1)] = $ln.Substring($i1 + 1) -replace "`t", ':'
        }
    } catch {}
    return $map
}

function Get-ScanZoneFiles {
    # Direct-child *.md files of mailboxes\<agent>\<zone>\ from a scan map.
    param([hashtable]$Scan, [string]$Agent, [string]$Zone)
    $prefix = (Join-Path (Join-Path $script:DirMailboxes $Agent) $Zone) + '\'
    $out = @()
    foreach ($k in $Scan.Keys) {
        if ($k.Length -gt $prefix.Length -and
            $k.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $k.IndexOf('\', $prefix.Length) -lt 0 -and
            $k -like '*.md') { $out += $k }
    }
    return ,$out
}

function Get-ScanTime {
    # Local DateTime from a "len:ticks" scan value; $null when absent.
    param([string]$Fp)
    if (-not $Fp -or $Fp -eq '0') { return $null }
    $i = $Fp.IndexOf(':')
    if ($i -lt 0) { return $null }
    try {
        return (New-Object datetime([long]$Fp.Substring($i + 1), [System.DateTimeKind]::Utc)).ToLocalTime()
    } catch { return $null }
}

function Ensure-AgentDirs {
    param([string]$Name, [string]$InboxRel)
    $inboxAbs = Join-Path $script:Root $InboxRel
    $agentDir = Split-Path $inboxAbs -Parent
    # Five-area mailbox: inbox / outbox / processing / sent (in-flight
    # originals) / notes (private thinking records). Existing mailboxes are
    # topped up in place - legacy messages stay where they are.
    foreach ($d in @((Join-Path $agentDir 'inbox'), (Join-Path $agentDir 'processing'), (Join-Path $agentDir 'outbox'),
                     (Join-Path $agentDir 'sent'), (Join-Path $agentDir 'notes'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $jd = Join-Path $script:DirLogs $Name
    if (-not (Test-Path -LiteralPath $jd)) { New-Item -ItemType Directory -Path $jd -Force | Out-Null }
    return $agentDir
}

function Write-Journal {
    param([string]$Agent, [string]$Action, [string]$Detail)
    $dir = Join-Path $script:DirLogs $Agent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = '{0} | {1,-9} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action, $Detail
    [System.IO.File]::AppendAllText((Join-Path $dir 'journal.log'), $line + "`r`n", $script:UTF8Bom)
}

function Write-SystemLog {
    param([string]$Detail)
    if (-not (Test-Path -LiteralPath $script:DirLogs)) { New-Item -ItemType Directory -Path $script:DirLogs -Force | Out-Null }
    $line = '{0} | {1,-9} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), 'SYSTEM', $Detail
    [System.IO.File]::AppendAllText((Join-Path $script:DirLogs 'system.log'), $line + "`r`n", $script:UTF8Bom)
}

function Get-SystemConfig {
    # System-wide tunables: config\system.json over sane defaults. Unknown
    # keys are preserved so the file can carry comments (the "//" key).
    $defaults = @{ rotate_size_mb = 2; rotate_keep = 4; stream_retention_days = 7;
                   sys_retention_days = 3; dead_after_dispatches = 3; poll_hooks = @{};
                   nudge_after_days = 7; auto_archive_after_days = 14; pending_stall_minutes = 60 }
    $path = Join-Path $script:Root 'config\system.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in ($j.PSObject.Properties)) { $defaults[$p.Name] = $p.Value }
        } catch {
            Write-SystemLog ('config\system.json unreadable, using defaults: ' + $_.Exception.Message)
        }
    }
    return $defaults
}

function New-MessageId {
    param([string]$From)
    $rand = ''
    1..4 | ForEach-Object { $rand += '{0:x}' -f (Get-Random -Maximum 16) }
    return ('msg-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $From + '-' + $rand)
}

function Move-AtomicTo {
    # Atomic rename on the same volume; retries on transient locks (readers), falls back to copy+delete.
    param([string]$File, [string]$DestPath)
    $dir = Split-Path $DestPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-Path -LiteralPath $DestPath)) {
            try { [System.IO.File]::Move($File, $DestPath); return $DestPath } catch { Start-Sleep -Milliseconds 150 }
        } else { break }
    }
    $bytes = [System.IO.File]::ReadAllBytes($File)
    [System.IO.File]::WriteAllBytes($DestPath, $bytes)
    [System.IO.File]::Delete($File)
    return $DestPath
}

function Move-Atomic {
    param([string]$File, [string]$DestDir)
    return (Move-AtomicTo -File $File -DestPath (Join-Path $DestDir ([System.IO.Path]::GetFileName($File))))
}

function Move-AtomicUnique {
    param([string]$File, [string]$DestDir)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $ext  = [System.IO.Path]::GetExtension($File)
    $dest = Join-Path $DestDir ($stem + $ext)
    $n = 2
    while (Test-Path -LiteralPath $dest) { $dest = Join-Path $DestDir ($stem + '-' + $n + $ext); $n++ }
    return (Move-AtomicTo -File $File -DestPath $dest)
}

function Copy-AtomicTo {
    # Copy so a reader never sees partial content: write to <dest>.part in the
    # destination directory, then rename (same volume -> atomic).
    param([string]$File, [string]$DestPath)
    $dir = Split-Path $DestPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $part = $DestPath + '.part'
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.IO.File]::Copy($File, $part, $true)
            if (Test-Path -LiteralPath $DestPath) { [System.IO.File]::Delete($DestPath) }
            [System.IO.File]::Move($part, $DestPath)
            return $DestPath
        } catch { Start-Sleep -Milliseconds 150 }
    }
    throw ('Copy-AtomicTo failed: ' + $File + ' -> ' + $DestPath)
}

function Copy-MailAtomic {
    param([string]$File, [string]$DestDir)
    return (Copy-AtomicTo -File $File -DestPath (Join-Path $DestDir ([System.IO.Path]::GetFileName($File))))
}

function Set-MailStatus {
    # Authoritative in-flight state sidecar (<id>.status) next to the master
    # copy in the sender's sent area. Keys are ASCII; values may be any text.
    # Holds current state only - full history lives in the journal. topic/peer
    # are set once and preserved across updates; status/updated always refresh;
    # reason is only meaningful for RETURNED/REJECTED/STALLED states.
    param([string]$MessagePath, [string]$Status, [string]$Reason = '', [string]$Topic = '', [string]$Peer = '')
    $side = [System.IO.Path]::ChangeExtension($MessagePath, '.status')
    $prev = @{}
    if (Test-Path -LiteralPath $side) {
        foreach ($ln in [System.IO.File]::ReadAllLines($side)) {
            if ($ln -match '^([A-Za-z0-9_\-]+):\s*(.*)$') { $prev[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
    if (-not $Topic) { $Topic = [string]$prev['topic'] }
    if (-not $Peer)  { $Peer  = [string]$prev['peer'] }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $nl = "`r`n"
    $content = 'status: '  + $Status + $nl +
               'reason: '  + $Reason + $nl +
               'updated: ' + $stamp  + $nl +
               'topic: '   + $Topic  + $nl +
               'peer: '    + $Peer   + $nl
    Write-TextFile -Path $side -Content $content
    return $side
}

function Get-MailStatus {
    param([string]$MessagePath)
    $side = [System.IO.Path]::ChangeExtension($MessagePath, '.status')
    $st = @{}
    if (Test-Path -LiteralPath $side) {
        foreach ($ln in [System.IO.File]::ReadAllLines($side)) {
            if ($ln -match '^([A-Za-z0-9_\-]+):\s*(.*)$') { $st[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
    return $st
}

function Add-ManifestEntry {
    # Integrity ledger: one SHA256 line per delivered/archived file, per topic.
    param([string]$Topic, [string]$Path)
    if (-not (Test-Path -LiteralPath $script:DirManifest)) { New-Item -ItemType Directory -Path $script:DirManifest -Force | Out-Null }
    if (-not $Topic) { $Topic = 'general' }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    $rel = $Path
    if ($rel.StartsWith($script:Root, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($script:Root.Length + 1) }
    $line = '{0} | {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $rel, $hash
    [System.IO.File]::AppendAllText((Join-Path $script:DirManifest ($Topic + '.manifest')), $line + "`r`n", $script:UTF8Bom)
}

function Protect-TopicDir {
    # Layer-1 lockdown (v2), portable edition: mark every file in the closed
    # topic directory read-only. Blocks edits/deletes via normal APIs without
    # touching ACLs (which misbehave across NAS mounts), keeps the archive
    # fully readable, and never blocks the ledger check. Deeper tampering is
    # the integrity ledger's job.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop)) {
            if (-not $f.IsReadOnly) { Set-ItemProperty -LiteralPath $f.FullName -Name IsReadOnly -Value $true }
        }
        return $true
    } catch { return $false }
}

function Unprotect-TopicDir {
    # Clear the read-only marks again (post office writes on a re-close).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop)) {
            if ($f.IsReadOnly) { Set-ItemProperty -LiteralPath $f.FullName -Name IsReadOnly -Value $false }
        }
        return $true
    } catch { return $false }
}

function Get-AgentFromPath {
    # <root>\mailboxes\<agent>\inbox\<file>  ->  agent name, else $null
    param([string]$FilePath)
    $pattern = [regex]::Escape($script:DirMailboxes) + '\\([^\\]+)\\inbox\\'
    if ($FilePath -match $pattern) { return $Matches[1] }
    return $null
}

function Get-OutboxOwner {
    # <root>\mailboxes\<agent>\outbox\<file>  ->  agent name (the outbox owner,
    # the anti-spoofing anchor), else $null
    param([string]$FilePath)
    $pattern = [regex]::Escape($script:DirMailboxes) + '\\([^\\]+)\\outbox\\'
    if ($FilePath -match $pattern) { return $Matches[1] }
    return $null
}

function Test-AgentBusy {
    # Fresh recipient activity in processing (letters, heartbeats) or notes
    # (thinking records) means the agent is mid-session. route.ps1 uses this
    # to skip the wake (single-session CLIs reject a second one anyway) and
    # the watch sweep uses it to skip spawning the route child at all.
    # Mtime-only, same dual-track liveness the cleanup requeue honours.
    # -Scan fast path (v2.2): a Get-MailboxScan map already carries every
    # mtime under mailboxes\ - answering from it re-walks nothing. The probe
    # path stays for child processes (route.ps1) that have no scan in hand.
    # -LogDir (2026-11-08): live-session transcript mirror, the liveness
    # signal agent cards declare for themselves (hermes: stream=logs\hermes\
    # stream-*.jsonl). processing/notes mtimes go quiet while a chain-copy
    # letter is being worked (the letter never leaves the inbox) and between
    # heartbeat writes, so a headless session minutes into a long tool call
    # looked idle and got woken again - observed 2026-11-08 05:28:45 t-q2wd.
    # Only stream-*.jsonl counts: lock files and dispatch logs are touched by
    # the post office itself, not by the agent.
    param([string]$AgentDir, [int]$FreshMinutes = 30, [hashtable]$Scan = $null, [string]$LogDir = '')
    if (-not $AgentDir) { return $false }
    $cutoff = (Get-Date).AddMinutes(-[Math]::Max(1, $FreshMinutes))
    if ($LogDir) {
        try {
            foreach ($p in [System.IO.Directory]::GetFiles($LogDir, 'stream-*.jsonl')) {
                $fi = New-Object System.IO.FileInfo($p)
                if ($fi.Exists -and $fi.LastWriteTime -gt $cutoff) { return $true }
            }
        } catch {}
    }
    if ($Scan) {
        try {
            foreach ($zone in @('processing', 'notes')) {
                $prefix = (Join-Path $AgentDir $zone) + '\'
                foreach ($k in $Scan.Keys) {
                    if (-not $k.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($k.IndexOf('\', $prefix.Length) -ge 0) { continue }   # direct children only, like the probe path
                    $t = Get-ScanTime -Fp $Scan[$k]
                    if ($t -and $t -gt $cutoff) { return $true }
                }
            }
        } catch {}
        return $false
    }
    if (-not (Test-Path -LiteralPath $AgentDir)) { return $false }
    try {
        foreach ($zone in @('processing', 'notes')) {
            $d = Join-Path $AgentDir $zone
            if (-not [System.IO.Directory]::Exists($d)) { continue }
            foreach ($p in [System.IO.Directory]::GetFiles($d)) {
                $fi = New-Object System.IO.FileInfo($p)
                if ($fi.Exists -and $fi.LastWriteTime -gt $cutoff) { return $true }
            }
        }
    } catch {}
    return $false
}

function New-SystemMailId {
    $rand = ''
    1..4 | ForEach-Object { $rand += '{0:x}' -f (Get-Random -Maximum 16) }
    return ('sys-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $rand)
}

function Write-SystemMail {
    # Post-office service mail (receipts, bounces, stall reports), written
    # straight into the agent's inbox by the daemon. Ids are sys-* so the
    # watcher never auto-routes them (no wake storms); a caller may still
    # invoke route.ps1 explicitly when the agent must act right away (bounce).
    param([string]$To, [string]$Topic, [string]$Subject, [string]$Body, [string]$InReplyTo = '')
    $inbox = Join-Path (Join-Path $script:DirMailboxes $To) 'inbox'
    if (-not (Test-Path -LiteralPath $inbox)) { throw ('inbox missing for ' + $To) }
    $id = New-SystemMailId
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $nl = "`r`n"
    $fm = '---' + $nl +
          'id: ' + $id + $nl +
          'topic: ' + $Topic + $nl +
          'from: postmaster' + $nl +
          'to: ' + $To + $nl +
          'type: broadcast' + $nl +
          'subject: ' + $Subject + $nl
    if ($InReplyTo) { $fm += 'in_reply_to: ' + $InReplyTo + $nl }
    $fm += 'created: ' + $stamp + $nl +
           'state: open' + $nl +
           '---' + $nl + $nl + $Body + $nl
    $path = Join-Path $inbox ($id + '.md')
    Write-TextFile -Path $path -Content $fm
    return $path
}

function Update-RegistryField {
    param([string]$Agent, [string]$Key, [string]$Value)
    $path = Join-Path $script:DirRegistry ($Agent + '.md')
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    # Invalidate the Get-RegisteredAgents memo: same-process callers that
    # update a card and re-read the roster must not see the pre-write state.
    $global:AKRegCache = $null
    $text = [System.IO.File]::ReadAllText($path)
    $pattern = '(?m)^(' + [regex]::Escape($Key) + '\s*):.*$'
    if ($text -match $pattern) {
        $text = [regex]::Replace($text, $pattern, ('$1: ' + $Value))
    } else {
        $text = $text.TrimEnd() + "`r`n$Key" + ': ' + $Value + "`r`n"
    }
    [System.IO.File]::WriteAllText($path, $text, $script:UTF8Bom)
    return $true
}

function Test-RouteFlag {
    param([string]$MessageId)
    return (Test-Path -LiteralPath (Join-Path $script:DirRouted ($MessageId + '.flag')))
}

function Set-RouteFlag {
    param([string]$MessageId)
    Write-TextFile -Path (Join-Path $script:DirRouted ($MessageId + '.flag')) -Content 'routed'
}

function Update-Dashboard {
    $d = Join-Path $PSScriptRoot 'dashboard.ps1'
    if (Test-Path -LiteralPath $d) { & $d -Root $script:Root -Quiet }
}

function Get-TopicStartDate {
    # t-20261001-c20f -> 2026-10-01 (the date the topic was initiated), else $null
    param([string]$Topic)
    if ($Topic -match '^t-(\d{4})(\d{2})(\d{2})-') {
        try { return (New-Object datetime([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])) } catch { return $null }
    }
    return $null
}

function Format-ModelValue {
    # Trim a model value and drop a trailing inline comment ("glm-5.3-flash   # note").
    param([string]$Value)
    $v = [string]$Value
    $v = $v.Trim()
    if ($v -match '^([^#]*?)\s+#') { $v = $Matches[1].Trim() }
    return $v
}

function Get-AgentModel {
    # Model id declared on the agent's registry card ('model:' field), else ''.
    param([string]$AgentName)
    if (-not $AgentName) { return '' }
    $card = Join-Path $script:DirRegistry ($AgentName + '.md')
    if (-not (Test-Path -LiteralPath $card)) { return '' }
    $fm = Read-FrontMatter -Path $card
    return (Format-ModelValue -Value ([string]$fm['model']))
}

function Get-TopicArchiveDir {
    # archive\<from>\<yyyy>\<MM>\<dd>\<topic> - date comes from the topic id
    # (the day the topic was initiated), falling back to $FallbackDate / today.
    param([string]$FromAgent, [string]$Topic, [datetime]$FallbackDate)
    $d = Get-TopicStartDate -Topic $Topic
    if (-not $d) { $d = $FallbackDate }
    if (-not $d -or $d -eq [datetime]::MinValue) { $d = (Get-Date) }
    $p = Join-Path $script:DirArchive $FromAgent
    foreach ($part in @($d.ToString('yyyy'), $d.ToString('MM'), $d.ToString('dd'), $Topic)) { $p = Join-Path $p $part }
    return $p
}

function Merge-SummaryFrontMatter {
    # Fill/refresh the index-relevant front-matter of a topic summary: topic,
    # title (falls back to the request subject), from/to, from_model/to_model
    # (message-declared 'model' wins, else the registry card), date, closed.
    # Existing non-empty values are preserved; missing ones are backfilled.
    param([string]$Path, [string]$Topic, [string]$From, [string]$To, [string]$Closed)
    $fm = Read-FrontMatter -Path $Path
    $dir = Split-Path $Path -Parent
    $reqSubject = ''; $toModelMsg = ''
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'summary.md') { continue }
        $m = Read-FrontMatter -Path $f.FullName
        if (([string]$m['type'] -eq 'request') -and -not $reqSubject) { $reqSubject = [string]$m['subject'] }
        if (([string]$m['from'] -eq $To) -and ([string]$m['model']) -and -not $toModelMsg) { $toModelMsg = [string]$m['model'] }
    }
    $title = [string]$fm['title']
    if (-not $title -or $title -match 'no title|一句话概括') { $title = $reqSubject }
    if (-not $title) { $title = $Topic }
    $tpd = Get-TopicStartDate -Topic $Topic
    $date = [string]$fm['date']
    if (-not $date -and $tpd) { $date = $tpd.ToString('yyyy-MM-dd') }
    $fromModel = Format-ModelValue -Value ([string]$fm['from_model'])
    if (-not $fromModel) { $fromModel = Get-AgentModel -AgentName $From }
    $toModel = (Format-ModelValue -Value $toModelMsg)
    if (-not $toModel) { $toModel = (Format-ModelValue -Value ([string]$fm['to_model'])) }
    if (-not $toModel) { $toModel = Get-AgentModel -AgentName $To }
    $closedVal = [string]$fm['closed']
    if (-not $closedVal) { $closedVal = $Closed }
    $vals = @{ topic = $Topic; title = $title; from = $From; from_model = $fromModel
               to = $To; to_model = $toModel; date = $date; closed = $closedVal }
    $order = @('topic','title','from','from_model','to','to_model','date','closed')
    $text = [System.IO.File]::ReadAllText($Path)
    $lines = @()
    $used = @{}
    foreach ($k in $order) { $lines += ($k + ': ' + [string]$vals[$k]); $used[$k] = $true }
    foreach ($k in $fm.Keys) { if (-not $used.ContainsKey($k)) { $lines += ($k + ': ' + [string]$fm[$k]) } }
    $newFm = "---`r`n" + ($lines -join "`r`n") + "`r`n---`r`n"
    if ($text -match '(?s)\A---\r?\n.*?\r?\n---\s*(\r?\n)?') {
        $text = $newFm + "`r`n" + $text.Substring($Matches[0].Length)
    } else {
        $text = $newFm + "`r`n" + $text
    }
    Write-TextFile -Path $Path -Content $text
}

function Update-ArchiveIndexes {
    # Rebuild archive\index.md (global, newest first) and archive\<agent>\_index.md
    # (that agent's initiated/received view) from all summary.md files.
    $items = @()
    foreach ($f in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Filter 'summary.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-FrontMatter -Path $f.FullName
        $tp = [string]$fm['topic']
        if (-not $tp) { $tp = (Split-Path (Split-Path $f.FullName -Parent) -Leaf) }
        $ti = [string]$fm['title']; if (-not $ti) { $ti = '(no title)' }
        $fr = [string]$fm['from']; $to = [string]$fm['to']
        $frm = Format-ModelValue -Value ([string]$fm['from_model']); if (-not $frm) { $frm = Get-AgentModel -AgentName $fr }
        $tom = Format-ModelValue -Value ([string]$fm['to_model']);   if (-not $tom) { $tom = Get-AgentModel -AgentName $to }
        $dt = [string]$fm['date']
        if (-not $dt) { $tpd = Get-TopicStartDate -Topic $tp; if ($tpd) { $dt = $tpd.ToString('yyyy-MM-dd') } }
        if (-not $dt) { $dt = $f.LastWriteTime.ToString('yyyy-MM-dd') }
        $cl = [string]$fm['closed']; if (-not $cl) { $cl = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $rel = $f.FullName.Substring($script:DirArchive.Length + 1).Replace('\', '/')
        $items += New-Object PSObject -Property @{ topic=$tp; title=$ti; from=$fr; to=$to
            from_model=$frm; to_model=$tom; date=$dt; closed=$cl; rel=$rel }
    }
    $items = @($items | Sort-Object -Property @{Expression='closed';Descending=$true})

    $rows = ''
    foreach ($it in $items) {
        $rows += ('| ' + $it.date + ' | [' + $it.topic + '](' + $it.rel + ') | ' + $it.title +
                  ' | ' + $it.from + ' (' + $it.from_model + ') | ' + $it.to + ' (' + $it.to_model +
                  ') | ' + $it.closed + " |`r`n")
    }
    $idx = ('# 归档索引' + "`r`n`r`n" +
        '结构：archive\<发起agent>\<yyyy>\<MM>\<dd>\<话题>\；条件查询：`scripts\archive-query.ps1`（-Agent/-With/-From/-To/-Model/-Date/-Month/-Year/-Topic/-Keyword）；单人视图：`archive\<agent>\_index.md`。' +
        "`r`n`r`n| 日期 | 话题 | 标题 | 发起方(模型) | 收件方(模型) | 结案时间 |`r`n|---|---|---|---|---|---|`r`n" + $rows)
    Write-TextFile -Path (Join-Path $script:DirArchive 'index.md') -Content $idx

    $agents = @{}
    foreach ($it in $items) {
        if ($it.from) { $agents[[string]$it.from] = $true }
        if ($it.to)   { $agents[[string]$it.to]   = $true }
    }
    foreach ($a in ($agents.Keys | Sort-Object)) {
        $rows2 = ''
        foreach ($it in ($items | Where-Object { $_.from -eq $a -or $_.to -eq $a })) {
            if ($it.from -eq $a) {
                $link = $it.rel.Substring($a.Length + 1)
                $dirn = '发起→'
            } else {
                $link = '../' + $it.rel
                $dirn = '←收到'
            }
            $peer =  if ($it.from -eq $a) { $it.to } else { $it.from }
            $peerM = if ($it.from -eq $a) { $it.to_model } else { $it.from_model }
            $rows2 += ('| ' + $it.date + ' | [' + $it.topic + '](' + $link + ') | ' + $it.title +
                       ' | ' + $dirn + ' | ' + $peer + ' (' + $peerM + ') | ' + $it.closed + " |`r`n")
        }
        $idx2 = ('# ' + $a + ' 的对话索引' + "`r`n`r`n" +
            '| 日期 | 话题 | 标题 | 方向 | 对端(模型) | 结案时间 |' + "`r`n|---|---|---|---|---|---|`r`n" + $rows2)
        Write-TextFile -Path (Join-Path (Join-Path $script:DirArchive $a) '_index.md') -Content $idx2
    }
}

# v3 topic state machine + neutral thread documents (r4.1).
. (Join-Path $PSScriptRoot 'threads.ps1')
