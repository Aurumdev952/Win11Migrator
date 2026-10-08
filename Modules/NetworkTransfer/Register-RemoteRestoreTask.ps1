<#
========================================================================================================
    Title:          Win11Migrator - Admin Share Push (domain PCs)
    Filename:       Register-RemoteRestoreTask.ps1
    Description:    For PCs nobody is sitting at: the export writes the package to \\TARGET\C$\Win11Migrator
                    with admin credentials, then a one-time logon task restores it as the target user.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Connect-AdminShare {
    <#
    .SYNOPSIS
        Authenticates to \\ComputerName\C$ for this logon session and returns the storage target for export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    $share = "\\$ComputerName\C`$"
    $null = Invoke-NetUse @($share, '/delete', '/y')
    $mapped = Invoke-NetUse @($share, $Credential.GetNetworkCredential().Password, "/user:$($Credential.UserName)", '/persistent:no')
    if ($mapped.ExitCode -ne 0) {
        throw "Cannot open $share with these credentials: $($mapped.Output)"
    }
    return @{ Type = 'AdminShare'; Path = $share; Computer = $ComputerName }
}

function New-RestoreTaskCommand {
    # The flag file makes the task a no-op after its first run, so later logons do nothing.
    # These are paths on the target PC, so they are composed as text rather than resolved here.
    param([Parameter(Mandatory)][string]$LocalPackagePath, [Parameter(Mandatory)][string]$LocalMigratorPath)
    $flag = "$LocalPackagePath\restore-started.flag"
    $script = "$LocalMigratorPath\Win11Migrator.ps1"
    return "if (-not (Test-Path '$flag')) { New-Item -ItemType File -Path '$flag' -Force | Out-Null; & '$script' -CLI import -PackagePath '$LocalPackagePath' -MoveFromPackage }"
}

function Register-RemoteRestoreTask {
    <#
    .SYNOPSIS
        Registers a task on the target PC that restores the package when TargetUserName next logs on,
        so HKCU settings and the profile folders belong to that user.
    .PARAMETER PackageName
        Folder name of the package under C:\Win11Migrator on the target.
    .OUTPUTS
        PSCustomObject with Registered and Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$TargetUserName,
        [Parameter(Mandatory)][string]$PackageName
    )

    $migratorPath = 'C:\Win11Migrator'
    $packagePath = "$migratorPath\$PackageName"
    $taskName = 'Win11Migrator Restore'

    $cim = $null
    try {
        try {
            $cim = New-CimSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        } catch {
            $cim = New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        }

        $command = New-RestoreTaskCommand -LocalPackagePath $packagePath -LocalMigratorPath $migratorPath
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUserName
        $trigger.EndBoundary = (Get-Date).AddDays(14).ToString('s')
        $principal = New-ScheduledTaskPrincipal -UserId $TargetUserName -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 12) -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)

        Register-ScheduledTask -CimSession $cim -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        return [PSCustomObject]@{
            Registered = $true
            Message    = "The restore starts when $TargetUserName next signs in to $ComputerName."
        }
    } catch {
        Write-MigrationLog -Message "Could not register the restore task on $($ComputerName): $($_.Exception.Message)" -Level Warning
        return [PSCustomObject]@{
            Registered = $false
            Message    = "The package is on $ComputerName at $packagePath. Sign in there as $TargetUserName and run $migratorPath\Win11Migrator.bat, then choose Import. ($($_.Exception.Message))"
        }
    } finally {
        if ($cim) { Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue }
    }
}
