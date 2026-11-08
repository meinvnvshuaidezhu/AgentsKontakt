param(
  [Parameter(Mandatory=$true)][string]$Topic,
  [Parameter(Mandatory=$true)][string]$Agent,
  [string]$Summary,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'common.ps1')

# v2 close = archive request execution. Pipeline:
#   archive gate (closer must be the topic initiator) ->
#   gather (working copies win, sent-area masters deduped away) ->
#   summary (+ related_topic backfill) -> manifest -> two-level indexes ->
#   directory lockdown.
# The gate is enforced technically: a non-initiator close is refused with a
# reason and an ARCHIVE-DENIED system mail.

# ---- collect topic candidates from every mailbox ----
$gathered = @()   # working copies (inbox / processing)
$masters  = @()   # sent-area masters (content duplicates of delivered mail)
$all = Get-ChildItem -LiteralPath $script:DirMailboxes -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue
foreach ($f in $all) {
    if ($f.FullName -notmatch '\\(inbox|processing|sent)\\') { continue }
    if ($f.Name -like 'sys-*') { continue }
    $fm = Read-FrontMatter -Path $f.FullName
    if ([string]$fm['topic'] -ne $Topic) { continue }
    if ($f.FullName -match '\\sent\\') { $masters += New-Object PSObject -Property @{ file = $f.FullName; fm = $fm } }
    else { $gathered += New-Object PSObject -Property @{ file = $f.FullName; fm = $fm } }
}

# ---- initiator: request message first, then existing summary, then archive ----
$initiator = ''; $recipient = ''
foreach ($g in $gathered) {
    if ([string]$g.fm['type'] -eq 'request') { $initiator = [string]$g.fm['from']; $recipient = [string]$g.fm['to']; break }
}
foreach ($m in $masters) {
    if (-not $initiator -and [string]$m.fm['type'] -eq 'request') { $initiator = [string]$m.fm['from']; $recipient = [string]$m.fm['to'] }
}
if (-not $initiator -or -not $recipient) {
    $existing = Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Filter 'summary.md' -File -ErrorAction SilentlyContinue |
        Where-Object { (Split-Path (Split-Path $_.FullName -Parent) -Leaf) -eq $Topic }
    if ($existing) {
        $sfm = Read-FrontMatter -Path $existing[0].FullName
        if (-not $initiator) { $initiator = [string]$sfm['from'] }
        if (-not $recipient) { $recipient = [string]$sfm['to'] }
    }
}
if (-not $initiator -or -not $recipient) {
    foreach ($f in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        if ($f.Directory.Name -ne $Topic) { continue }
        $afm = Read-FrontMatter -Path $f.FullName
        if (([string]$afm['topic'] -eq $Topic) -and ([string]$afm['type'] -eq 'request')) {
            if (-not $initiator) { $initiator = [string]$afm['from'] }
            if (-not $recipient) { $recipient = [string]$afm['to'] }
            break
        }
    }
}
if (-not $initiator) { $initiator = $Agent }
if (-not $recipient) { $recipient = 'unknown' }

# ---- archive gate ----
if ($initiator -ne 'unknown' -and $Agent -ne $initiator) {
    Write-Journal -Agent $Agent -Action 'DENIED' -Detail ('topic=' + $Topic + ' | closer=' + $Agent + ' | initiator=' + $initiator)
    $body = (Get-AkLines 'close.denied.body' 'Archive request denied.' '' 'topic: {0}' 'closer: {1}' 'initiator: {2}' '' 'Only the topic initiator may close and archive a topic.' |
        ForEach-Object { $_ -f $Topic, $Agent, $initiator }) -join "`r`n"
    $mail = Write-SystemMail -To $Agent -Topic $Topic -Subject ('ARCHIVE-DENIED ' + $Topic) -Body $body
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'route.ps1') -File $mail -Root $Root 2>&1
    Write-Host (Get-AkText 'close.denied' 'DENIED topic {0} (closer {1} is not the initiator {2})' $Topic $Agent $initiator)
    exit 1
}

# ---- destination (unlock first on a re-close) ----
$earliest = $null
foreach ($g in $gathered) {
    $c = $null
    try { $c = [datetime]::Parse([string]$g.fm['created']) } catch {}
    if ($c -and (-not $earliest -or $c -lt $earliest)) { $earliest = $c }
}
# $earliest can be $null when the topic already has no working copies left
# (re-close of an archived topic); pass the MinValue sentinel like migrate-archive.
$fb = if ($earliest) { $earliest } else { [datetime]::MinValue }
$destDir = Get-TopicArchiveDir -FromAgent $initiator -Topic $Topic -FallbackDate $fb
if (Test-Path -LiteralPath $destDir) { Unprotect-TopicDir -Path $destDir | Out-Null }

# ---- gather: working copies win, masters dedupe away ----
$archivedIds = @{}
foreach ($g in $gathered) {
    $mid = [string]$g.fm['id']
    if (-not $mid) { $mid = [System.IO.Path]::GetFileNameWithoutExtension($g.file) }
    $dest = Move-AtomicUnique -File $g.file -DestDir $destDir
    $archivedIds[$mid] = $true
    Add-ManifestEntry -Topic $Topic -Path $dest
    $side = Join-Path (Split-Path $g.file -Parent) ($mid + '.progress')
    if (Test-Path -LiteralPath $side) {
        $dside = Move-AtomicUnique -File $side -DestDir $destDir
        Add-ManifestEntry -Topic $Topic -Path $dside
    }
}
foreach ($m in $masters) {
    $mid = [string]$m.fm['id']
    if (-not $mid) { $mid = [System.IO.Path]::GetFileNameWithoutExtension($m.file) }
    if ($archivedIds.ContainsKey($mid)) {
        # content duplicate of the archived working copy - drop the master
        Remove-Item -LiteralPath $m.file -Force
        $st = [System.IO.Path]::ChangeExtension($m.file, '.status')
        if (Test-Path -LiteralPath $st) { Remove-Item -LiteralPath $st -Force }
        Write-Journal -Agent $initiator -Action 'DEDUPE' -Detail ($mid + ' | master dropped, working copy archived')
    } else {
        $dest = Move-AtomicUnique -File $m.file -DestDir $destDir
        $archivedIds[$mid] = $true
        Add-ManifestEntry -Topic $Topic -Path $dest
        $st = [System.IO.Path]::ChangeExtension($m.file, '.status')
        if (Test-Path -LiteralPath $st) { Move-AtomicUnique -File $st -DestDir $destDir | Out-Null }
    }
}

# ---- summary ----
$stamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
$summaryPath = Join-Path $destDir 'summary.md'
if (-not (Test-Path -LiteralPath $summaryPath)) {
    if ($Summary -and (Test-Path -LiteralPath $Summary)) {
        Move-AtomicTo -File (Resolve-Path -LiteralPath $Summary).Path -DestPath $summaryPath | Out-Null
    } else {
        $tpl = Read-TextFile -Path (Join-Path $script:DirTemplates 'summary-template.md')
        $subject = ''
        foreach ($src in @($gathered + $masters)) {
            if ([string]$src.fm['type'] -eq 'request') {
                $s = [string]$src.fm['subject']
                if ($s) { $subject = $s; break }
            }
        }
        if (-not $subject) { $subject = $Topic }
        $tplDate = Get-TopicStartDate -Topic $Topic
        if (-not $tplDate) { $tplDate = $earliest }
        if (-not $tplDate -or $tplDate -eq [datetime]::MinValue) { $tplDate = (Get-Date) }
        $tpl = $tpl.Replace('{topic}', $Topic).Replace('{title}', $subject).Replace('{from}', $initiator).Replace('{to}', $recipient).Replace('{date}', $tplDate.ToString('yyyy-MM-dd')).Replace('{closed}', $stamp)
        Write-TextFile -Path $summaryPath -Content $tpl
    }
}
Merge-SummaryFrontMatter -Path $summaryPath -Topic $Topic -From $initiator -To $recipient -Closed $stamp

# related_topic backfill into the summary front-matter (v2 lineage)
$relTopic = ''
foreach ($src in @($gathered + $masters)) {
    $r = [string]$src.fm['related_topic']
    if ($r) { $relTopic = $r; break }
}
if (-not $relTopic) {
    foreach ($f in (Get-ChildItem -LiteralPath $destDir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'summary.md') { continue }
        $rfm = Read-FrontMatter -Path $f.FullName
        $r = [string]$rfm['related_topic']
        if ($r) { $relTopic = $r; break }
    }
}
if ($relTopic) {
    $text = [System.IO.File]::ReadAllText($summaryPath)
    if ($text -notmatch '(?m)^related_topic:') {
        $text = [regex]::Replace($text, '(?m)^closed: (.*)$', ("closed: `$1`r`nrelated_topic: " + $relTopic))
        Write-TextFile -Path $summaryPath -Content $text
    }
}
Add-ManifestEntry -Topic $Topic -Path $summaryPath

# ---- indexes, ledger, lockdown ----
Update-ArchiveIndexes
Write-Journal -Agent $Agent -Action 'CLOSE' -Detail ('topic=' + $Topic + ' gathered=' + $gathered.Count + ' masters=' + $masters.Count)
Update-Dashboard
$locked = Protect-TopicDir -Path $destDir
if (-not $locked) { Write-SystemLog ('topic dir lock failed (ledger remains the guard): ' + $destDir) }
Write-Host (Get-AkText 'close.closed' 'CLOSED topic {0} gathered={1} -> {2}{3}' $Topic $gathered.Count $destDir $(if ($locked) { Get-AkText 'close.locked' ' (locked)' } else { '' }))
