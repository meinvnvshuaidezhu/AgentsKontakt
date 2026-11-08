# threads.ps1 - v3 topic state machine + neutral thread document library.
# Dot-sourced AFTER common.ps1 (needs $script:Root, Read/Write-TextFile,
# Move-AtomicTo, Copy-AtomicTo, Read-FrontMatter, Write-Journal, Write-SystemMail,
# Write-SystemLog, Get-SystemConfig, Update-ArchiveIndexes, Protect-TopicDir).
#
# Implements docs\协议修订案-v3-状态机与中立文档.md (r4.1):
#   - status.json single-source state machine (pending/processing/answered/archived)
#   - neutral thread document chain under post\threads\<topic>\ (thread-<n>.md)
#   - per-topic lock file (.lock, 10s retry, 60s zombie reclaim)
#   - atomic appends with kind field + id dedupe + 64KB split
#   - overwrite-style chain copies (<topic>.chain.md)
#   - three-source trace test (status.json / journal THREAD·STATE / sent)
#   - JSONL archive index (single-writer, line-tolerant) + one-shot backfill
#   - redirect (pending -> pending, post office executed)
#
# State transitions and their writers (§2.2):
#   pending -> processing          recipient (claim)
#   processing -> answered         recipient (send.ps1; dead-recipient case: redirect/close)
#   answered -> pending            initiator (follow-up question via send.ps1)
#   answered -> archived           initiator (manual) | post office (auto after 14d)
#   processing -> pending          post office (stall demotion)
#   pending -> pending             post office (redirect, initiator-triggered)
# archived is terminal: no out-edges, no reopen.

$script:DirThreads = Join-Path $script:DirPost 'threads'
$script:ThreadSplitBytes = 64KB
$script:ChainWarnBytes   = 256KB

function Get-ThreadsRoot {
    if (-not (Test-Path -LiteralPath $script:DirThreads)) {
        New-Item -ItemType Directory -Path $script:DirThreads -Force | Out-Null
    }
    return $script:DirThreads
}

function Get-ThreadDir {
    param([string]$Topic)
    return (Join-Path (Get-ThreadsRoot) $Topic)
}

function Get-StatusPath {
    param([string]$Topic)
    return (Join-Path (Get-ThreadDir -Topic $Topic) 'status.json')
}

# ---------------------------------------------------------------- status.json

function Get-TopicStatus {
    # Tolerant reader: a torn write (crash mid-rename) is treated as transient
    # and retried once; persistent failure returns $null (caller decides).
    param([string]$Topic)
    $p = Get-StatusPath -Topic $Topic
    for ($i = 0; $i -lt 2; $i++) {
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        try {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
            return $j
        } catch { Start-Sleep -Milliseconds 120 }
    }
    Write-SystemLog ('threads: status.json unreadable (kept): ' + $p)
    return $null
}

function Set-TopicStatus {
    # Merge-write via temp+rename (§2.1 lock discipline). Fields not passed are
    # preserved from the current file. Returns the written object.
    param([string]$Topic, [hashtable]$Fields)
    $p = Get-StatusPath -Topic $Topic
    $dir = Get-ThreadDir -Topic $Topic
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = $null
    if (Test-Path -LiteralPath $p) {
        try { $obj = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { $obj = $null }
    }
    if (-not $obj) {
        $obj = New-Object PSObject -Property @{ topic = $Topic; from = ''; to = ''; state = 'pending'
            last_heartbeat = ''; state_updated_by = ''; state_updated_at = ''
            chain = @(); chain_bytes = 0; delivered_at = ''; copies = @{} }
    }
    foreach ($k in $Fields.Keys) {
        if ($obj.PSObject.Properties[$k]) { $obj.PSObject.Properties[$k].Value = $Fields[$k] }
        else { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Fields[$k] }
    }
    $json = $obj | ConvertTo-Json -Depth 10
    $tmp = $p + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $script:UTF8Bom)   # P1-1: program data file -> BOM per r4.1 §2.7
    if (Test-Path -LiteralPath $p) { [System.IO.File]::Delete($p) }
    [System.IO.File]::Move($tmp, $p)
    return $obj
}

# ---------------------------------------------------------------- per-topic lock

function Get-TopicLock {
    # .lock exclusive-create; 10s of 150ms retries; a lock older than 60s is a
    # zombie (holder died): alarm + record PID, then reclaim. $null = could not
    # acquire (caller logs and aborts the mutation).
    param([string]$Topic)
    $dir = Get-ThreadDir -Topic $Topic
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lockPath = Join-Path $dir '.lock'
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = [System.Text.Encoding]::ASCII.GetBytes("pid=$PID born=$(Get-Date -Format o)")
            $fs.Write($info, 0, $info.Length); $fs.Flush()
            return @{ path = $lockPath; stream = $fs }
        } catch [System.IO.IOException] {
            # held by someone; check zombie age below, then retry
        } catch { return $null }
        try {
            $fi = New-Object System.IO.FileInfo($lockPath)
            if ($fi.Exists -and $fi.LastWriteTime -lt (Get-Date).AddSeconds(-60)) {
                Write-SystemLog ('threads: zombie lock reclaimed (>60s): ' + $lockPath)
                [System.IO.File]::Delete($lockPath)
            }
        } catch {}
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Release-FileLock {
    # Shared closer for any { path; stream } lock record (topic locks and the
    # archive index lock share the same shape and the same discipline).
    param($Lock)
    if (-not $Lock) { return }
    try { if ($Lock.stream) { $Lock.stream.Close() } } catch {}
    try { if (Test-Path -LiteralPath $Lock.path) { [System.IO.File]::Delete($Lock.path) } } catch {}
}

function Release-TopicLock {
    param($Lock)
    Release-FileLock -Lock $Lock
}

# ---------------------------------------------------------------- thread chain

function Get-LetterBody {
    # Front-matter-stripped letter body (what becomes a thread turn).
    param([string]$Path)
    $text = Read-TextFile -Path $Path
    if ($text -match '(?s)\A---\r?\n.*?\r?\n---\s*(\r?\n|$)') { $text = $text.Substring($Matches[0].Length) }
    return $text.Trim()
}

function Get-ThreadChainFiles {
    # thread-*.md of the topic sorted by seq (thread-1, thread-2, ...).
    param([string]$Topic)
    $dir = Get-ThreadDir -Topic $Topic
    if (-not (Test-Path -LiteralPath $dir)) { return ,@() }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Filter 'thread-*.md' -ErrorAction SilentlyContinue |
        Sort-Object Name)
    return ,$files
}

function New-ThreadTopic {
    # First turn of a new topic: thread-1.md (kind-bearing block) + status.json
    # (pending). Returns the status object. Caller holds no lock (single create:
    # existing status.json -> refuse, caller treats as follow-up instead).
    param([string]$Topic, [string]$From, [string]$To, [string]$Subject,
          [string]$Body, [string]$Kind = 'question', [string]$MsgId, [string]$NotePath = '')
    $dir = Get-ThreadDir -Topic $Topic
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $statusPath = Get-StatusPath -Topic $Topic
    if (Test-Path -LiteralPath $statusPath) {
        throw ('threads: topic already exists: ' + $Topic)
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $nl = "`r`n"
    $fm = '---' + $nl +
          'topic: ' + $Topic + $nl +
          'from: ' + $From + $nl +
          'to: ' + $To + $nl +
          'seq: 1' + $nl +
          'created: ' + $stamp + $nl +
          '---' + $nl + $nl
    $turnLabel = switch ($Kind) {
        'answer'       { 'appended answer' }
        'archive-note' { 'appended archive note' }
        default        { 'opened the topic' }
    }
    $turn = '## [' + $stamp + '] ' + $From + ' ' + $turnLabel + $nl +
        '<!-- kind: ' + $Kind + ' -->' + $nl + '<!-- id: ' + $MsgId + ' -->' + $nl + $nl +
        $Body + $nl
    $thinkRef = ''
    if ($NotePath) { $thinkRef = $nl + '思考链：' + $NotePath + $nl }
    Write-TextFile -Path (Join-Path $dir 'thread-1.md') -Content ($fm + $turn + $thinkRef)
    $st = Set-TopicStatus -Topic $Topic -Fields @{
        topic = $Topic; from = $From; to = $To; state = 'pending'
        last_heartbeat = $stamp; state_updated_by = 'postmaster'; state_updated_at = $stamp
        chain = @('thread-1.md'); chain_bytes = (Get-Item -LiteralPath (Join-Path $dir 'thread-1.md')).Length
        delivered_at = ''; subject = $Subject
        copies = @{}
    }
    Write-Journal -Agent $From -Action 'THREAD' -Detail ('new topic ' + $Topic + ' | ' + $From + '->' + $To)
    return $st
}

function Add-ThreadEntry {
    # Append a turn (kind-bearing) to the live thread file under the per-topic
    # lock. Enforces: kind required, id dedupe (chain-wide), processing blocks
    # new questions, 64KB split. Returns the (possibly new) status object.
    param([string]$Topic, [string]$Agent, [string]$Kind, [string]$MsgId,
          [string]$Body, [string]$NotePath = '')
    if ($Kind -notin @('question', 'answer', 'archive-note')) {
        throw ('threads: invalid kind ' + $Kind)
    }
    $lock = Get-TopicLock -Topic $Topic
    if (-not $lock) { throw ('threads: topic lock busy: ' + $Topic) }
    try {
        $st = Get-TopicStatus -Topic $Topic
        if (-not $st) { throw ('threads: no status.json for ' + $Topic) }
        # id dedupe across the whole chain (restart-safe; watcher retries must
        # never double-append - 2026-11-06 incident path). Q6 (t-20261107-ix07,
        # workbuddy zero-cost item): stream with Select-String -SimpleMatch
        # instead of slurping every chain file into memory - the write path
        # needs the verdict, not the text.
        $dir = Get-ThreadDir -Topic $Topic
        $dedupeNeedle = '<!-- id: ' + $MsgId + ' -->'
        foreach ($cf in (Get-ThreadChainFiles -Topic $Topic)) {
            if (Select-String -LiteralPath $cf.FullName -SimpleMatch $dedupeNeedle -Quiet) {
                Write-Journal -Agent $Agent -Action 'STATE' -Detail ('dedupe: ' + $MsgId + ' already in chain of ' + $Topic)
                return (Get-TopicStatus -Topic $Topic)
            }
        }
        # processing blocks new questions (round-robin machine-enforced)
        if ($st.state -eq 'processing' -and $Kind -eq 'question') {
            throw ('threads: topic ' + $Topic + ' is processing - follow-up questions must wait for answered (round-robin)')
        }
        $files = Get-ThreadChainFiles -Topic $Topic
        if (-not $files.Count) { throw ('threads: chain missing for ' + $Topic) }
        $live = $files[-1]
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $nl = "`r`n"
        $turnLabel = switch ($Kind) {
            'answer'       { 'appended answer' }
            'archive-note' { 'appended archive note' }
            default        { 'appended a follow-up question' }
        }
        $turn = $nl + '---' + $nl + '## [' + $stamp + '] ' + $Agent + ' ' + $turnLabel + $nl +
            '<!-- kind: ' + $Kind + ' -->' + $nl + '<!-- id: ' + $MsgId + ' -->' + $nl + $nl +
            $Body + $nl
        if ($NotePath) { $turn += $nl + '思考链：' + $NotePath + $nl }
        $livePath = $live.FullName
        [System.IO.File]::AppendAllText($livePath, $turn, $script:UTF8Bom)
        # split: live file over 64KB -> freeze it read-only, open the next seq
        $chain = @($st.chain); $chainBytes = 0
        if ((Get-Item -LiteralPath $livePath).Length -gt $script:ThreadSplitBytes) {
            Set-ItemProperty -LiteralPath $livePath -Name IsReadOnly -Value $true
            $nextSeq = $files.Count + 1
            $nextName = 'thread-' + $nextSeq + '.md'
            $nextFm = '---' + $nl +
                'topic: ' + $Topic + $nl +
                'from: ' + [string]$st.from + $nl +
                'to: ' + [string]$st.to + $nl +
                'seq: ' + $nextSeq + $nl +
                'inherits:' + $nl +
                '  - ' + $live.Name + $nl +
                'created: ' + $stamp + $nl +
                '---' + $nl
            Write-TextFile -Path (Join-Path $dir $nextName) -Content $nextFm
            $chain += $nextName
            Write-SystemLog ('threads: chain split at ' + $live.Name + ' -> ' + $nextName + ' (' + $Topic + ')')
        }
        foreach ($cf in (Get-ThreadChainFiles -Topic $Topic)) { $chainBytes += $cf.Length }
        $fields = @{ chain = $chain; chain_bytes = $chainBytes; state_updated_at = $stamp }
        switch ($Kind) {
            'answer'       { if ($st.state -ne 'answered') { $fields.state = 'answered'; $fields.state_updated_by = $Agent; $fields.state_updated_at = $stamp } }
            'question'     { if ($st.state -notin @('pending', 'processing')) { $fields.state = 'pending'; $fields.state_updated_by = $Agent; $fields.state_updated_at = $stamp } }
            'archive-note' { $fields.state = 'archived'; $fields.state_updated_by = $Agent; $fields.state_updated_at = $stamp; $fields.archived_at = $stamp }
        }
        $st = Set-TopicStatus -Topic $Topic -Fields $fields
        Write-Journal -Agent $Agent -Action 'STATE' -Detail ($Topic + ' append kind=' + $Kind + ' id=' + $MsgId + ' state=' + $st.state)
        return $st
    } finally { Release-TopicLock -Lock $lock }
}

function Get-ThreadChainText {
    # Full chain concatenated (the content a recipient reads / a copy carries).
    param([string]$Topic)
    $sb = New-Object System.Text.StringBuilder
    foreach ($cf in (Get-ThreadChainFiles -Topic $Topic)) {
        [void]$sb.Append((Read-TextFile -Path $cf.FullName))
        [void]$sb.Append("`r`n")
    }
    return $sb.ToString()
}

function Copy-ThreadChainTo {
    # Overwrite-style chain copy: <topic>.chain.md into an inbox, atomic via
    # .part rename. One file per topic per inbox - never accumulates.
    param([string]$Topic, [string]$InboxDir)
    $text = Get-ThreadChainText -Topic $Topic
    $dest = Join-Path $InboxDir ($Topic + '.chain.md')
    $tmp = $dest + '.part'
    [System.IO.File]::WriteAllText($tmp, $text, $script:UTF8Bom)
    if (Test-Path -LiteralPath $dest) { [System.IO.File]::Delete($dest) }
    [System.IO.File]::Move($tmp, $dest)
    return $dest
}

function Clear-ThreadCopies {
    # Remove every copy of the topic from an agent's inbox AND processing
    # (§3 step 4: the answering side must leave zero traces, including the
    # v2 habit of claiming into processing). Failures are NOT silent:
    # CLEANUP_FAILED in the journal + $false return.
    param([string]$Topic, [string]$Agent)
    $ok = $true
    foreach ($zone in @('inbox', 'processing')) {
        $d = Join-Path (Join-Path $script:DirMailboxes $Agent) $zone
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $targets = @()
        try { $targets = @(Get-ChildItem -LiteralPath $d -File -Filter ($Topic + '.*') -ErrorAction SilentlyContinue) } catch { continue }
        foreach ($f in $targets) {
            for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $f.FullName); $i++) {
                try { [System.IO.File]::Delete($f.FullName) } catch { Start-Sleep -Milliseconds 300 }
            }
            if (Test-Path -LiteralPath $f.FullName) {
                Write-Journal -Agent $Agent -Action 'CLEANUP_FAILED' -Detail ($Topic + ' | could not remove ' + $f.Name)
                Write-SystemLog ('threads: cleanup failed (locked?): ' + $f.FullName)
                $ok = $false
            }
        }
    }
    return $ok
}

# ---------------------------------------------------------------- trace (3-source)

function Test-TopicTrace {
    # Three-source v3-trace test (§2.6): any hit = the topic exists in v3.
    #   1. post\threads\<topic>\status.json
    #   2. journal THREAD/STATE line for the topic
    #   3. sent\ holds a letter whose front-matter topic matches
    # Returns 'v3' | 'legacy-suspect' | 'legacy'.
    param([string]$Topic, [string]$From = '', [string]$To = '')
    if (Test-Path -LiteralPath (Get-StatusPath -Topic $Topic)) { return 'v3' }
    # 2. journals (every agent dir, rotations included)
    try {
        foreach ($jd in (Get-ChildItem -LiteralPath $script:DirLogs -Directory -ErrorAction SilentlyContinue)) {
            foreach ($jf in (Get-ChildItem -LiteralPath $jd.FullName -File -Filter 'journal*.log' -ErrorAction SilentlyContinue)) {
                $lines = [System.IO.File]::ReadAllLines($jf.FullName)
                foreach ($ln in $lines) {
                    if ($ln -match ('(THREAD|STATE).*' + [regex]::Escape($Topic))) { return 'v3' }
                }
            }
        }
    } catch {}
    # 3. sent area (either side)
    foreach ($a in @($From, $To) | Where-Object { $_ }) {
        $sd = Join-Path (Join-Path $script:DirMailboxes $a) 'sent'
        if (-not (Test-Path -LiteralPath $sd)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::GetFiles($sd, '*.md')) {
                $fm = Read-FrontMatter -Path $f
                if ([string]$fm['topic'] -eq $Topic) { return 'v3' }
            }
        } catch {}
    }
    # weak corroboration: a v2 SEND record leans legacy, none at all is suspect
    try {
        foreach ($jd in (Get-ChildItem -LiteralPath $script:DirLogs -Directory -ErrorAction SilentlyContinue)) {
            foreach ($jf in (Get-ChildItem -LiteralPath $jd.FullName -File -Filter 'journal*.log' -ErrorAction SilentlyContinue)) {
                if (([System.IO.File]::ReadAllText($jf.FullName)) -match ('SEND.*' + [regex]::Escape($Topic))) { return 'legacy' }
            }
        }
    } catch {}
    return 'legacy-suspect'
}

# ---------------------------------------------------------------- archive (JSONL)

function Get-ArchiveIndexLock {
    # archive\index.lock - same discipline as the per-topic lock.
    $p = Join-Path $script:DirArchive 'index.lock'
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return @{ path = $p; stream = $fs }
        } catch [System.IO.IOException] {} catch { return $null }
        try {
            $fi = New-Object System.IO.FileInfo($p)
            if ($fi.Exists -and $fi.LastWriteTime -lt (Get-Date).AddSeconds(-60)) {
                Write-SystemLog ('threads: zombie archive index lock reclaimed: ' + $p)
                [System.IO.File]::Delete($p)
            }
        } catch {}
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Get-ArchiveJsonlPath { return (Join-Path $script:DirArchive 'index.jsonl') }

function Add-ArchiveJsonlRecord {
    # One JSON line per archived topic, UTF-8 no-BOM (§2.7). Single-writer via
    # the archive index lock. Idempotent: an existing topic line is replaced in
    # place (rewrite file without it, then append fresh).
    param([hashtable]$Record)
    $lock = Get-ArchiveIndexLock
    if (-not $lock) { throw 'threads: archive index lock busy' }
    try {
        $path = Get-ArchiveJsonlPath
        $lines = @()
        if (Test-Path -LiteralPath $path) {
            foreach ($ln in [System.IO.File]::ReadAllLines($path)) {
                if (-not $ln.Trim()) { continue }
                try {
                    $o = $ln | ConvertFrom-Json
                    if ([string]$o.topic -ne [string]$Record['topic']) { $lines += $ln }
                } catch { $lines += $ln }   # line-tolerant: keep bad lines, count them
            }
        }
        $lines += ($Record | ConvertTo-Json -Compress -Depth 6)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)
    } finally { Release-TopicLock -Lock $lock }
}

function Invoke-TopicArchive {
    # Move chain + status.json (final state) into the archive dir, clear
    # post\threads\<topic>\, write the JSONL record (both parties queryable),
    # regenerate the md human view, lockdown. Returns the archive dir.
    param([string]$Topic, [string]$ClosedBy)
    $lock = Get-TopicLock -Topic $Topic
    if (-not $lock) { throw ('threads: topic lock busy: ' + $Topic) }
    try {
        $st = Get-TopicStatus -Topic $Topic
        if (-not $st) { throw ('threads: no status.json for ' + $Topic) }
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $fields = @{ state = 'archived'; state_updated_by = $ClosedBy; state_updated_at = $stamp; archived_at = $stamp }
        $null = Set-TopicStatus -Topic $Topic -Fields $fields
        $from = [string]$st.from
        $destDir = Get-TopicArchiveDir -FromAgent $from -Topic $Topic -FallbackDate (Get-Date)
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Unprotect-TopicDir -Path $destDir | Out-Null
        foreach ($f in (Get-ThreadChainFiles -Topic $Topic)) {
            $dest = Move-AtomicTo -File $f.FullName -DestPath (Join-Path $destDir $f.Name)
            Add-ManifestEntry -Topic $Topic -Path $dest
        }
        $stFinal = Get-StatusPath -Topic $Topic
        if (Test-Path -LiteralPath $stFinal) {
            $dest = Move-AtomicTo -File $stFinal -DestPath (Join-Path $destDir 'status.json')
            Add-ManifestEntry -Topic $Topic -Path $dest
        }
        # (thread dir cleanup happens after the lock release - see below)
        # summary.md (index-relevant front matter, same shape as v2 archives)
        $summaryPath = Join-Path $destDir 'summary.md'
        if (-not (Test-Path -LiteralPath $summaryPath)) {
            $subject = [string]$st.subject; if (-not $subject) { $subject = $Topic }
            $tplDate = Get-TopicStartDate -Topic $Topic; if (-not $tplDate) { $tplDate = (Get-Date) }
            $content = "---`r`ntopic: $Topic`r`ntitle: $subject`r`nfrom: $([string]$st.from)`r`nto: $([string]$st.to)`r`ndate: $($tplDate.ToString('yyyy-MM-dd'))`r`nclosed: $stamp`r`n---`r`n"
            Write-TextFile -Path $summaryPath -Content $content
        }
        Add-ManifestEntry -Topic $Topic -Path $summaryPath
        # JSONL record (both parties)
        $rel = $destDir.Substring($script:DirArchive.Length + 1).Replace('\', '/')
        Add-ArchiveJsonlRecord -Record @{
            topic = $Topic; title = [string]$st.subject
            initiator = [string]$st.from; responder = [string]$st.to
            start_date = $(if ($d0 = Get-TopicStartDate -Topic $Topic) { $d0.ToString('yyyy-MM-dd') } else { (Get-Date).ToString('yyyy-MM-dd') })
            closed_time = $stamp; thread_ref = $rel; participants = @()
        }
        Update-ArchiveIndexes
        Protect-TopicDir -Path $destDir | Out-Null
        Write-Journal -Agent $ClosedBy -Action 'CLOSE' -Detail ('topic=' + $Topic + ' archived -> ' + $rel)
        $destDirOut = $destDir
    } finally { Release-TopicLock -Lock $lock }
    # Thread-dir cleanup runs AFTER the lock release: the .lock stream is still
    # held inside try, and Remove-Item on a directory with an open child handle
    # trips a PS 5.1 NullReferenceException. No orphans remain for the audit.
    $dir = Get-ThreadDir -Topic $Topic
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dir) { try { [System.IO.Directory]::Delete($dir) } catch {
        Write-SystemLog ('threads: post-archive dir cleanup deferred: ' + $dir)
    } }
    return $destDirOut
}

function Invoke-TopicRedirect {
    # Post-office-executed redirect (§2.2): initiator-triggered via send.ps1
    # -Redirect. Atomic six-step: reassign to, reset pending/timestamps, clear
    # the old recipient's copies, deliver the full chain to the new recipient,
    # journal STATE redirect, notify both (sys mail to the old, ring the new).
    param([string]$Topic, [string]$Initiator, [string]$NewTo)
    $lock = Get-TopicLock -Topic $Topic
    if (-not $lock) { throw ('threads: topic lock busy: ' + $Topic) }
    try {
        $st = Get-TopicStatus -Topic $Topic
        if (-not $st) { throw ('threads: no status.json for ' + $Topic) }
        if ([string]$st.state -ne 'pending') { throw ('threads: redirect only allowed from pending, topic ' + $Topic + ' is ' + [string]$st.state) }
        $oldTo = [string]$st.to
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $null = Set-TopicStatus -Topic $Topic -Fields @{
            to = $NewTo; state = 'pending'; delivered_at = ''
            last_heartbeat = $stamp; state_updated_by = 'postmaster'; state_updated_at = $stamp
        }
        if ($oldTo -and $oldTo -ne $NewTo) { $null = Clear-ThreadCopies -Topic $Topic -Agent $oldTo }
        $newInbox = Join-Path (Join-Path $script:DirMailboxes $NewTo) 'inbox'
        if (-not (Test-Path -LiteralPath $newInbox)) { throw ('threads: new recipient inbox missing: ' + $NewTo) }
        $copy = Copy-ThreadChainTo -Topic $Topic -InboxDir $newInbox
        # copies trace: old side cleared, new side delivered (§2.6 persistent evidence)
        $copies = @{}
        if ($st.copies) { foreach ($p in ($st.copies.PSObject.Properties)) { $copies[$p.Name] = $p.Value } }
        $oldEntry = @{}; if ($copies[$oldTo]) { foreach ($q in $copies[$oldTo].PSObject.Properties) { $oldEntry[$q.Name] = $q.Value } }
        $oldEntry['cleared_at'] = $stamp; $copies[$oldTo] = $oldEntry
        $copies[$NewTo] = @{ delivered_at = $stamp; bytes = [int]$st.chain_bytes; cleared_at = '' }
        $null = Set-TopicStatus -Topic $Topic -Fields @{ delivered_at = $stamp; copies = $copies }
        Write-Journal -Agent 'postmaster' -Action 'STATE' -Detail ($Topic + ' redirect ' + $oldTo + ' -> ' + $NewTo + ' (by ' + $Initiator + ')')
        $body = 'Topic ' + $Topic + ' was redirected to ' + $NewTo + ' by ' + $Initiator + '. Your copy has been cleared.'
        $null = Write-SystemMail -To $oldTo -Topic $Topic -Subject ('REDIRECTED ' + $Topic) -Body $body
        $null = Write-SystemMail -To $NewTo -Topic $Topic -Subject ('REDIRECTED-IN ' + $Topic) -Body ('Topic ' + $Topic + ' was redirected to you by ' + $Initiator + '. The full chain copy is in your inbox (state pending).')
        return @{ copy = $copy; oldTo = $oldTo; newTo = $NewTo }
    } finally { Release-TopicLock -Lock $lock }
}
