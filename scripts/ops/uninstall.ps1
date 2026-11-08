param(
    # Where the program files were installed.
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\AgentsKontakt",
    # Where the mailbox data lives. Empty: derive as <InstallDir>\data.
    [string]$DataDir = '',
    # pid of the uninstaller exe - the helper waits for it to exit
    [int]$WaitPid = 0
)

$ErrorActionPreference = 'Stop'
# normalize: callers may pass mixed-slash paths; the daemon sweep and every
# literal match below assume backslash form
$InstallDir = $InstallDir -replace '/', '\'
# data dir default: <InstallDir>\data (one folder for everything, 2026-11-02)
if (-not $DataDir) { $DataDir = Join-Path $InstallDir 'data' }
$DataDir = $DataDir -replace '/', '\'

Write-Host '=============================================================='
Write-Host ' AgentsKontakt Postman - uninstaller'
Write-Host '=============================================================='
Write-Host ("  install : {0}" -f $InstallDir)
Write-Host ("  data    : {0}" -f $DataDir)
Write-Host ''

# 1. autostart entry
try {
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $rk) {
        Remove-ItemProperty -Path $rk -Name 'AgentsKontaktPost' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $rk -Name 'AgentsKontaktPostDaemon' -ErrorAction SilentlyContinue
        Write-Host '  [ok] autostart entry removed'
    }
} catch {
    Write-Warning ("autostart cleanup failed: {0}" -f $_.Exception.Message)
}

# 1a-2. standard uninstall registration (symmetric removal, v2.2.6)
try {
    Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentsKontaktPost' -Recurse -Force -ErrorAction SilentlyContinue
try {
    $il = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentsKontaktPost' -ErrorAction SilentlyContinue).InstallLocation
    if ($il) {
        New-Item 'HKCU:\Software\AgentsKontakt' -Force | Out-Null
        Set-ItemProperty 'HKCU:\Software\AgentsKontakt' -Name 'LastInstallDir' -Value $il
        Write-Host '  [ok] LastInstallDir preserved for next install'
    }
} catch { }
    Write-Host '  [ok] standard uninstall entry removed'
} catch {
    Write-Warning ("uninstall entry removal failed: {0}" -f $_.Exception.Message)
}

# 1b. daemon scheduled task
$autostartPs = Join-Path $PSScriptRoot 'autostart.ps1'
if (Test-Path -LiteralPath $autostartPs) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $autostartPs -Action Unregister -DataDir $DataDir | Out-Null
        Write-Host '  [ok] daemon task removed'
    } catch {
        Write-Warning ("daemon task removal failed: {0}" -f $_.Exception.Message)
    }
}

# 1b-2. stop a running daemon for this data root (the scheduled task launches
# watch.ps1 standalone, so removing the task does not stop it - observed
# 2026-11-01: an uninstall left the daemon alive and the data dir locked)
try {
    $esc = [regex]::Escape($DataDir.TrimEnd(''))
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -replace '/', '\\') -match $esc -and $_.CommandLine -match 'watch\.ps1|mirror' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host ("  [ok] stopped running daemon pid=" + $_.ProcessId)
        }
} catch {
    Write-Warning ("daemon stop failed: {0}" -f $_.Exception.Message)
}

# 1c. defender exclusion (symmetric removal - no ownerless whitelist dirs)
$depPs = Join-Path $PSScriptRoot 'defender-exclusion.ps1'
if (Test-Path -LiteralPath $depPs) {
    $exRoots = @($DataDir)
    if (-not [string]::Equals($InstallDir.TrimEnd('\'), $DataDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        $exRoots += $InstallDir
    }
    # -File cannot collect repeated -Root into string[] (ParameterAlreadyBound,
    # reproduced 2026-10-31/11-01); -Command can. Local Continue: a stderr
    # record under Stop must not abort the uninstaller before the data purge.
    $depRoots = ($exRoots | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$depPs' -Action Unregister -Root $depRoots" 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
    } catch {
        Write-Warning ("defender unregister failed (non-fatal): {0}" -f $_.Exception.Message)
    }
    $ErrorActionPreference = $eap
}

# 2. shortcuts
# The name contains Chinese characters, so this file MUST keep its UTF-8 BOM -
# PowerShell 5.1 reads BOM-less files as GBK and the name would not match.
# The glob also catches leftovers created by an earlier BOM-less version.
$startMenu = [Environment]::GetFolderPath('StartMenu')
$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($dir in @($startMenu, $desktop)) {
    if ([string]::IsNullOrEmpty($dir)) { continue }
    foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter 'AgentsKontakt*.lnk' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue
        Write-Host ("  [ok] shortcut removed: {0}" -f $lnk.FullName)
    }
}

# 3. stop the postman if it is running
# The caller must be excluded: when the postman itself invokes this script
# (exe --uninstall), the postman process IS the parent of this script, and
# killing it would abort the uninstall half-way (the program files would
# never be removed and the exit code would be bogus).
$callerId = $PID
try {
    $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID) -ErrorAction SilentlyContinue
    if ($parent) { $callerId = [int]$parent.ParentProcessId }
} catch { }

Get-Process -Name AgentsKontaktPost -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Id -eq $callerId) {
        Write-Host ('  [--] postman is the caller - not killing it (pid ' + $_.Id + ')')
        return
    }
    try { $_.Kill(); Write-Host ('  [ok] postman stopped (pid ' + $_.Id + ')') } catch { }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    $cl = $_.CommandLine
    if ($_.ProcessId -eq $PID) { return }
    if ($cl -and $cl -like ('*' + $DataDir + '\scripts\watch.ps1*')) {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('  [ok] daemon stopped (pid ' + $_.ProcessId + ')') } catch { }
    }
}

# 4. program files
# The uninstall script itself may live inside the install directory, so the
# removal is done by a detached helper that keeps running after the tree is
# gone. Removing the tree from this very process would kill the script
# mid-flight and yield a bogus non-zero exit code.
# rename-then-delete: moving the dir aside first removes the race with a
# quick reinstall (the helper's retry window could otherwise delete the NEW
# install's files). If the rename fails (self-hosted exe lock), fall back
# to the in-place helper as before.
$origInstallDir = $InstallDir   # the rename below rewrites $InstallDir
try {
    Rename-Item -LiteralPath $InstallDir -NewName ('AgentsKontakt-deleting-' + $PID) -ErrorAction Stop
    $InstallDir = Join-Path (Split-Path $InstallDir -Parent) ('AgentsKontakt-deleting-' + $PID)
    Write-Host ('  [ok] program dir renamed for deletion: ' + $InstallDir)
} catch {
    Write-Host '  [--] rename failed - deleting in place'
}
if (Test-Path -LiteralPath $InstallDir) {
    # The helper has to live somewhere writable that is NOT inside the tree
    # being deleted (the data dir dies with the program since 2026-11-03).
    $helperName = 'ak_uninstall_' + [System.Diagnostics.Process]::GetCurrentProcess().Id + '.ps1'
    $helper = $null
    # the data dir is deleted together with the program (2026-11-03) - the
    # helper must not live there or the purge deletes it before it ever runs
    $candDirs = @($env:TEMP, $env:LOCALAPPDATA)
    foreach ($candidateDir in $candDirs) {
        if ([string]::IsNullOrEmpty($candidateDir)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidateDir)) { continue }
            $probe = Join-Path $candidateDir $helperName
            $payload = @"
`$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Milliseconds 1500
if ($WaitPid -gt 0) { Wait-Process -Id $WaitPid -Timeout 60 -ErrorAction SilentlyContinue }
$hStart = Get-Date
# the uninstaller exe (this dir\app) may still be exiting - retry while it unlocks
    if ((Test-Path -LiteralPath '$($InstallDir -replace "'", "''")') -and
        ((Get-Item -LiteralPath '$($InstallDir -replace "'", "''")').CreationTime -gt $hStart)) {
        Write-Host '  [--] program dir was repopulated (fresh install) - deletion aborted'
        return
    }
                for ($i = 0; $i -lt 4; $i++) {
                    if ((Test-Path -LiteralPath '$($InstallDir -replace "'", "''")') -and
                        ((Get-Item -LiteralPath '$($InstallDir -replace "'", "''")').CreationTime -gt $hStart)) {
                        Write-Host '  [--] program dir repopulated by a fresh install - deletion aborted'
                        break
                    }
                    Remove-Item -LiteralPath '$($InstallDir -replace "'", "''")' -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath '$($InstallDir -replace "'", "''")')) { break }
                    Start-Sleep -Seconds 2
                }
Remove-Item -LiteralPath '$($probe -replace "'", "''")' -Force -ErrorAction SilentlyContinue
"@
            Set-Content -LiteralPath $probe -Value $payload -Encoding UTF8 -ErrorAction Stop
            $helper = $probe
            break
        } catch { }
    }
    if ($helper) {
        try {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper) `
                -WindowStyle Hidden -ErrorAction Stop
            Write-Host ("  [ok] program files scheduled for removal: {0}" -f $InstallDir)
        } catch {
            # Fallback: remove in place and accept a partial result.
# RunOnce fallback: if anything is still locked, the next logon removes it
if (Test-Path -LiteralPath $InstallDir) {
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'AgentsKontaktCleanup' -Value ('cmd /c rmdir /s /q "' + $InstallDir + '"') -ErrorAction SilentlyContinue
    Write-Host '  [ok] RunOnce cleanup scheduled (leftover files)'
}
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ("  [ok] program files removed: {0}" -f $InstallDir)
        }
    } else {
        # No writable spot for the helper - remove in place.
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("  [ok] program files removed: {0}" -f $InstallDir)
    }
}

# 5. data - removed together with the program (2026-11-03, no keep option)
if (Test-Path -LiteralPath $DataDir) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("  [ok] data removed: {0}" -f $DataDir)
}

Write-Host ''
Write-Host ' Uninstall finished.'
