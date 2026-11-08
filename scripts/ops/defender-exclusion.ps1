param(
    [ValidateSet('Register','Unregister','Status')]
    [string]$Action = 'Status',
    # Directories to exclude. The data dir is the hot path (mail, archive,
    # logs, scripts - 600+ file touches per sweep); the program dir feeds
    # child-process script loads on the split layout. Both travel in one
    # elevation when they differ.
    [string[]]$Root = @(),
    # 'auto' = relaunch elevated via UAC when needed (a declined prompt is a
    # clean skip, never an install failure). 'never' = report-only; the
    # elevated child runs with this so the relaunch cannot recurse.
    [ValidateSet('auto','never')]
    [string]$Elevation = 'auto'
)

# ASCII output only: this file must parse identically whatever codepage a
# BOM-less reader assumes. Every exit 0 below is a SUCCESS-or-clean-skip;
# only real failures exit non-zero.
$ErrorActionPreference = 'Stop'

if (-not $Root -or $Root.Count -eq 0) {
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
    if (-not $d) { throw 'cannot locate project root (no registry\ found above the script); pass -Root' }
    $Root = @($d)
}
$Root = @($Root | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction Stop).Path.TrimEnd('\') })

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DefenderActive {
    try {
        $svc = Get-Service -Name WinDefend -ErrorAction Stop
        return ($svc.Status -eq 'Running')
    } catch { return $false }
}

function Test-Excluded {
    # Best-effort read: some builds/caches deny Get-MpPreference to non-admins;
    # callers treat $null as "cannot verify".
    param([string]$Path)
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        foreach ($p in @($pref.ExclusionPath)) {
            if ($p -and ($p.TrimEnd('\') -ieq $Path)) { return $true }
        }
        return $false
    } catch { return $null }
}

function Invoke-ElevatedSelf {
    # One UAC prompt for all roots. Returns $true (child exit 0), $false
    # (child failed) or $null (prompt declined / elevation unavailable).
    param([string]$ChildAction, [string[]]$ChildRoots)
    $argList = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Action ' + $ChildAction + ' -Elevation never'
    foreach ($r in $ChildRoots) { $argList += (' -Root "' + $r + '"') }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
        return ($p.ExitCode -eq 0)
    } catch { return $null }
}

if (-not (Test-DefenderActive)) {
    Write-Host '  [--] Microsoft Defender is not active - nothing to exclude'
    exit 0
}

if ($Action -eq 'Status') {
    foreach ($r in $Root) {
        $v = Test-Excluded -Path $r
        $state = if ($null -eq $v) { 'unknown (read needs admin)' } elseif ($v) { 'excluded' } else { 'NOT excluded' }
        Write-Host ('  {0} : {1}' -f $r, $state)
    }
    exit 0
}

if ($Action -eq 'Register') {
    $pending = @()
    foreach ($r in $Root) {
        $v = Test-Excluded -Path $r
        if ($null -eq $v -or -not $v) { $pending += $r }
    }
    if (-not $pending) {
        Write-Host ('  [ok] already excluded: ' + ($Root -join ', '))
        exit 0
    }
    if (Test-Admin) {
        try {
            foreach ($r in $pending) { Add-MpPreference -ExclusionPath $r -ErrorAction Stop }
        } catch {
            Write-Host ('  [--] Add-MpPreference failed: ' + $_.Exception.Message)
            exit 1
        }
    } else {
        if ($Elevation -ne 'auto') {
            Write-Host '  [--] admin rights required - skipped (unattended run)'
            exit 0
        }
        Write-Host '  [..] admin rights required - confirm the UAC prompt (declining just skips this step)'
        $ok = Invoke-ElevatedSelf -ChildAction 'Register' -ChildRoots $pending
        if ($null -eq $ok) {
            Write-Host '  [--] UAC declined - exclusion skipped (non-fatal)'
            exit 0
        }
        if (-not $ok) {
            Write-Host '  [--] elevated registration failed'
            exit 1
        }
    }
    $missing = @()
    foreach ($r in $pending) {
        if ((Test-Excluded -Path $r) -eq $false) { $missing += $r }
    }
    if ($missing) {
        Write-Host ('  [--] verification could not confirm: ' + ($missing -join ', '))
        exit 1
    }
    Write-Host ('  [ok] defender exclusion registered: ' + ($Root -join ', '))
    exit 0
}

# Unregister: symmetric removal on uninstall. A declined UAC leaves the
# exclusion in place - the user is told exactly how to remove it by hand.
$present = @()
foreach ($r in $Root) {
    if ((Test-Excluded -Path $r) -eq $true) { $present += $r }
}
if (-not $present) {
    Write-Host '  [--] no matching exclusion registered - nothing to remove'
    exit 0
}
if (Test-Admin) {
    try {
        foreach ($r in $present) { Remove-MpPreference -ExclusionPath $r -ErrorAction Stop }
    } catch {
        Write-Host ('  [--] Remove-MpPreference failed: ' + $_.Exception.Message)
        exit 1
    }
} else {
    if ($Elevation -ne 'auto') {
        Write-Host '  [--] admin rights required - exclusion left in place'
        exit 0
    }
    Write-Host '  [..] admin rights required - confirm the UAC prompt to remove the exclusion'
    $ok = Invoke-ElevatedSelf -ChildAction 'Unregister' -ChildRoots $present
    if ($null -eq $ok) {
        Write-Host ('  [--] UAC declined - exclusion remains on: ' + ($present -join ', '))
        Write-Host '       remove manually: Windows Security -> Exclusions, or'
        Write-Host ('       admin PowerShell: Remove-MpPreference -ExclusionPath "<path>"')
        exit 0
    }
    if (-not $ok) {
        Write-Host '  [--] elevated removal failed - exclusion may remain'
        exit 1
    }
}
$left = @()
foreach ($r in $present) {
    if ((Test-Excluded -Path $r) -eq $true) { $left += $r }
}
if ($left) {
    Write-Host ('  [--] removal could not be verified for: ' + ($left -join ', '))
    exit 1
}
Write-Host ('  [ok] defender exclusion removed: ' + ($present -join ', '))
exit 0
