param(
  [string]$Topic = '',
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

# v2 integrity check (layer 2): compare every archived file's SHA256 against
# the manifest recorded at delivery/archive time. Content-based - the file may
# have been moved since the entry was written, the hash is what must match.
# Files in an archive topic dir that no manifest hash covers are reported as
# unmanifested (planted or hand-edited). Stock topics without a manifest file
# are skipped. Exit 1 when anything failed.

if (-not (Test-Path -LiteralPath $script:DirManifest)) { Write-Host (Get-AkText 'integrity.no-manifest' 'integrity: no manifest yet'); exit 0 }

$manifests = Get-ChildItem -LiteralPath $script:DirManifest -File -Filter '*.manifest' -ErrorAction SilentlyContinue
if ($Topic) { $manifests = @($manifests | Where-Object { $_.BaseName -eq $Topic }) }

# Cheap pre-guard: one .NET walk builds an archive signature (every dir and
# file with len+mtime). Unchanged since the last completed run -> nothing new
# to verify, exit immediately. Forensic -Topic mode always runs in full.
$script:ArchSig = $null
if (-not $Topic) {
    $sigPath = Join-Path $script:DirManifest 'integrity.archsig'
    $sig = New-Object System.Text.StringBuilder
    try {
        foreach ($d in [System.IO.Directory]::GetDirectories($script:DirArchive, '*', [System.IO.SearchOption]::AllDirectories)) {
            [void]$sig.Append($d)
            foreach ($f in [System.IO.Directory]::GetFiles($d)) {
                $fi = New-Object System.IO.FileInfo($f)
                if (-not $fi.Exists) { continue }
                [void]$sig.Append('|').Append($fi.Name).Append(':').Append($fi.Length).Append(':').Append($fi.LastWriteTimeUtc.Ticks)
            }
            [void]$sig.Append("`n")
        }
    } catch { $sig.Length = 0 }   # walk failed: run the full check
    $oldSig = $null
    if ($sig.Length -gt 0 -and (Test-Path -LiteralPath $sigPath)) {
        try { $oldSig = [System.IO.File]::ReadAllText($sigPath) } catch {}
        if ($oldSig -eq $sig.ToString()) { Write-Host (Get-AkText 'integrity.unchanged' 'integrity: archive unchanged (sig match)'); exit 0 }
    }
    $script:ArchSig = $sig.ToString()
}

$checked = 0; $tampered = 0; $topics = 0; $cached = 0

# Single pass over the archive: one recursive walk builds the topic-dir index.
# Previously every manifest did its own full recursive search (O(manifests x
# tree)), and every sweep re-hashed every archived file - measured at 13% of a
# core per watch loop per minute. Topic dirs are fingerprinted (count/size/
# mtimes); an unchanged fingerprint since the last full hash pass skips the
# re-hash. -Topic (forensic mode) bypasses the cache and always hashes.
$dirIndex = @{}
try {
    foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:DirArchive, '*', [System.IO.SearchOption]::AllDirectories)) {
        $dirIndex[[System.IO.Path]::GetFileName($d)] = $d   # topic ids are unique; first-wins is not required
    }
} catch { Write-SystemLog ('integrity: archive walk error :: ' + $_.Exception.Message) }

function Get-DirSnapshot {
    # count + fingerprint of the checkable files (status sidecars and .part are
    # bookkeeping, excluded so their churn does not force re-hashing)
    param([string]$Dir)
    $cnt = 0; $sumLen = [long]0; $sumTicks = [long]0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir)) {
            $n = [System.IO.Path]::GetFileName($f)
            if ($n -like '*.status' -or $n -like '*.part') { continue }
            $fi = New-Object System.IO.FileInfo($f)
            $cnt++; $sumLen += $fi.Length; $sumTicks += $fi.LastWriteTimeUtc.Ticks
        }
    } catch { return $null }   # transient IO error: caller falls back to a full pass
    return @{ count = $cnt; fp = ('{0}|{1}|{2}' -f $cnt, $sumLen, $sumTicks) }
}

$cachePath = Join-Path $script:DirManifest 'integrity.fp'
$cache = @{}
# Line format: "<topic><TAB><count|sumLen|sumTicks>" - the fingerprint itself
# contains '|', so the topic/record separator must not be '|'.
if (-not $Topic -and (Test-Path -LiteralPath $cachePath)) {
    foreach ($ln in [System.IO.File]::ReadAllLines($cachePath)) {
        $p = $ln -split "`t", 2; if ($p.Count -ge 2 -and $p[0]) { $cache[$p[0]] = $p[1] }
    }
}
$cacheDirty = $false

foreach ($mf in $manifests) {
    $t = $mf.BaseName
    $hashes = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($mf.FullName)) {
        if ($ln -match '\| ([0-9a-f]{64})\s*$') { $hashes[$Matches[1]] = $true }
    }
    if ($hashes.Count -eq 0) { continue }
    # PowerShell 5.1: Hashtable hides IDictionary.TryGetValue behind an explicit
    # interface implementation - use ContainsKey + indexer instead.
    if (-not $dirIndex.ContainsKey($t)) { continue }
    $dirPath = $dirIndex[$t]
    $topics++
    $snap = Get-DirSnapshot -Dir $dirPath
    if ($null -eq $snap) { $snap = @{ count = 0; fp = '' } }
    if (-not $Topic -and $snap.fp -ne '' -and $cache.ContainsKey($t) -and $cache[$t] -eq $snap.fp) {
        $checked += $snap.count   # verified unchanged since the last full hash pass
        $cached++
        continue
    }
    # Ledger birthday: files last written before the topic's manifest existed
    # are v1-era stock (this topic dir predates the ledger). Grandfather them
    # once by baselining their hash into the manifest; edits after the
    # baseline still fail the check below. Without this every sweep flags
    # every legacy file (449 false TAMPERs in the first hours of v2).
    $ledgerBirth = $mf.CreationTime
    foreach ($f in (Get-ChildItem -LiteralPath $dirPath -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -like '*.status') { continue }   # status sidecars are bookkeeping, not history
        if ($f.Name -like '*.part')   { continue }
        $checked++
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        if (-not $hashes.ContainsKey($h)) {
            if ($f.LastWriteTime -lt $ledgerBirth) {
                Add-ManifestEntry -Topic $t -Path $f.FullName
                $hashes[$h] = $true
                Write-SystemLog ('BASELINE legacy file ledgered: topic=' + $t + ' file=' + $f.Name)
                continue
            }
            $tampered++
            Write-Host (Get-AkText 'integrity.tamper' 'TAMPER {0} | {1} | hash not in manifest' $t $f.Name)
            Write-SystemLog ('TAMPER topic=' + $t + ' file=' + $f.FullName)
        }
    }
    $cache[$t] = $snap.fp
    $cacheDirty = $true
}

# report-once semantics: a cached (unchanged) topic dir stays quiet until its
# content moves - the old code re-reported the same TAMPER every sweep.
if ($cacheDirty -and -not $Topic) {
    $lines = @($cache.Keys | ForEach-Object { "{0}`t{1}" -f $_, $cache[$_] })
    [System.IO.File]::WriteAllLines($cachePath, $lines, $script:UTF8Bom)
}
if ($script:ArchSig) {
    [System.IO.File]::WriteAllText((Join-Path $script:DirManifest 'integrity.archsig'), $script:ArchSig, $script:UTF8Bom)
}

Write-Host (Get-AkText 'integrity.summary' 'integrity: topics={0} files={1} tampered={2} cached={3}' $topics $checked $tampered $cached)
if ($tampered -gt 0) { exit 1 }
exit 0
