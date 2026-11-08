param(
    # Register (default) or remove the daemon autostart task.
    [ValidateSet('Register', 'Unregister', 'Status')]
    [string]$Action = 'Register',
    # The mailbox data root (the directory holding scripts\watch.ps1).
    [string]$DataDir = '',
    # The task name shown in Task Scheduler.
    [string]$TaskName = 'AgentsKontakt Postman'
)

$ErrorActionPreference = 'Stop'

if (-not $DataDir) {
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
    if ($d) { $DataDir = $d } else { $DataDir = Split-Path $PSScriptRoot -Parent }
}
$watch = Join-Path $DataDir 'scripts\watch.ps1'
if (-not (Test-Path -LiteralPath $watch)) { $watch = (Join-Path $PSScriptRoot '..\watch.ps1') }

function Get-Task {
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch { return $null }
}

switch ($Action) {
    'Status' {
        $t = Get-Task
        if (-not $t) { Write-Host '  not registered'; break }
        $i = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ('  state     : ' + $t.State)
        Write-Host ('  last run  : ' + $i.LastRunTime)
        Write-Host ('  last result: ' + $i.LastTaskResult)
        break
    }

    'Unregister' {
        $t = Get-Task
        if (-not $t) { Write-Host '  [--] no task named "' + $TaskName + '"'; break }
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host ('  [ok] task removed: ' + $TaskName)
        } catch {
            Write-Warning ('task removal failed: ' + $_.Exception.Message)
        }
        break
    }

    'Register' {
        if (-not (Test-Path -LiteralPath $watch)) {
            throw ('watch.ps1 not found: ' + $watch)
        }
        # Launch the daemon through "conhost --headless".
        #
        # Why not just "powershell.exe -WindowStyle Hidden"? Because that flag
        # only hides the console window the process allocates for ITSELF.
        # When Windows decides that Windows Terminal is the console host
        # (the default when HKCU\Console\%%Startup has no explicit host),
        # the console is delegated to WT over DCOM and the window WT shows
        # is NOT the one -WindowStyle Hidden applies to. The daemon then
        # runs with a visible terminal window on the user's desktop.
        #
        # "conhost --headless" gives the daemon a console with no visible
        # window at all, so there is nothing for the host to delegate.
        $daemonArgs = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $watch + '" -Root "' + $DataDir + '"'
        try {
            $act = New-ScheduledTaskAction -Execute 'conhost.exe' `
                -Argument $daemonArgs `
                -WorkingDirectory $DataDir
            # -AtLogOn without -User needs elevation; scoping it to the current
            # user keeps the whole thing non-admin.
            $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
            $t = New-ScheduledTask -Action $act -Trigger $trg -Settings $st `
                -Description 'AgentsKontakt post-office daemon (watch.ps1)'
            # Re-registering over an existing task fails with "cannot create
            # the file when it already exists", so drop the old one first.
            if (Get-Task) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
            Register-ScheduledTask -InputObject $t -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-Host ('  [ok] task registered: ' + $TaskName)
            Write-Host ('       action: conhost.exe --headless powershell.exe ... watch.ps1')
        } catch {
            Write-Warning ('task registration failed: ' + $_.Exception.Message)
            Write-Warning '  fall back to HKCU Run key for autostart'
            try {
                $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
                if (-not (Test-Path $rk)) { New-Item -Path $rk -Force | Out-Null }
                $exe = Join-Path $DataDir 'app\AgentsKontaktPost.exe'
                if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $DataDir 'AgentsKontaktPost.exe' }
                Set-ItemProperty -Path $rk -Name 'AgentsKontaktPostDaemon' `
                    -Value ('conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $watch + '" -Root "' + $DataDir + '"') `
                    -Type String
                Write-Host '  [ok] HKCU Run fallback registered'
            } catch {
                Write-Warning ('HKCU Run fallback failed: ' + $_.Exception.Message)
                # Both layers failed: tell the caller (the exe) so it does not
                # report success.
                exit 1
            }
            break
        }

        # Start it right away so the post office is live without waiting for
        # the next logon.
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host '  [ok] task started'
        } catch {
            Write-Warning ('task start failed: ' + $_.Exception.Message)
        }
        break
    }
}
