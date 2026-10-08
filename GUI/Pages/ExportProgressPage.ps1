<#
========================================================================================================
    Title:          Win11Migrator - Export Progress Page
    Filename:       ExportProgressPage.ps1
    Description:    Shows real-time progress during the migration package export process.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ExportProgressPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store all controls in a single hashtable so closures capture them via .GetNewClosure()
    $ui = @{
        Title     = $Page.FindName('txtExportTitle')
        Phase     = $Page.FindName('txtExportPhase')
        Progress  = $Page.FindName('progressExport')
        Percent   = $Page.FindName('txtExportPercent')
        Current   = $Page.FindName('txtCurrentItem')
        Rate      = $Page.FindName('txtExportRate')
        Log       = $Page.FindName('txtExportLog')
    }
    $formatRate = ${function:Format-TransferRate}

    # Disable navigation during export
    $State.BtnNext.IsEnabled = $false
    $State.BtnBack.IsEnabled = $false

    $selection = @{
        Apps            = $State.Apps
        UserData        = $State.UserData
        BrowserProfiles = $State.BrowserProfiles
        AppProfiles     = $State.AppProfiles
        SettingsFlags   = @{}
        IncludeAppData  = $true
        UseUSMT         = [bool]($State.Config.USMTAvailable -and $State.Config.USMTPath)
        Exclusions      = if ($State.Exclusions) { $State.Exclusions } else { Get-MigrationExclusions -Config $State.Config }
    }
    foreach ($flag in (Get-AllSettingsFlags).Keys) { $selection.SettingsFlags[$flag] = [bool]$State[$flag] }

    $requiredBytes = [long](@($State.UserData | Where-Object { $_.Selected -and -not $_.SkipCloudSync }) |
        Measure-Object -Property SizeBytes -Sum).Sum

    # Resolve the destination up front so "not enough space" stops the export before anything is copied
    try {
        $destination = Resolve-ExportDestination -StorageTarget $State.StorageTarget -RequiredBytes $requiredBytes -LocalPackageRoot $State.Config.PackagePath
    } catch {
        $ui.Title.Text = "Cannot start export"
        $ui.Phase.Text = $_.Exception.Message
        $State.BtnBack.IsEnabled = $true
        return
    }

    $resume = $false
    if (-not $State.EncryptPackage) {
        $unfinished = Find-ResumablePackage -Root $destination.Root
        if ($unfinished) {
            $answer = [System.Windows.MessageBox]::Show(
                "An unfinished export from this PC was found:`n$unfinished`n`nResume it? Files already copied are skipped.",
                "Resume export", 'YesNo', 'Question')
            $resume = ($answer -eq 'Yes')
        }
    }

    $exportProgress = [hashtable]::Synchronized(@{
        Phase      = 'Preparing...'
        Percent    = 0
        Item       = ''
        Log        = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        BytesTotal = $requiredBytes
        BytesDone  = 0L
        StartedUtc = $null
        Done       = $false
    })

    $ctx = @{ Job = $null; Progress = $exportProgress }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('State', $State)
    $runspace.SessionStateProxy.SetVariable('Selection', $selection)
    $runspace.SessionStateProxy.SetVariable('Destination', $destination)
    $runspace.SessionStateProxy.SetVariable('Resume', $resume)
    $runspace.SessionStateProxy.SetVariable('prog', $exportProgress)
    $runspace.SessionStateProxy.SetVariable('MigratorRoot', $State.MigratorRoot)
    $runspace.SessionStateProxy.SetVariable('Config', $State.Config)
    $runspace.SessionStateProxy.SetVariable('MigratorVersion', $script:MigratorVersion)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        foreach ($core in 'Initialize-Environment', 'Write-MigrationLog', 'ConvertTo-MigrationManifest', 'Invoke-Robocopy',
                          'Get-MigrationExclusions', 'Invoke-MigrationExport', 'Protect-MigrationPackage') {
            . (Join-Path $MigratorRoot "Core\$core.ps1")
        }
        foreach ($module in 'UserData', 'BrowserProfiles', 'SystemSettings', 'AppProfiles', 'StorageTargets', 'USMT', 'NetworkTransfer') {
            Get-ChildItem (Join-Path $MigratorRoot "Modules\$module\*.ps1") -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
        }
        $script:MigratorRoot = $MigratorRoot
        $script:MigratorVersion = $MigratorVersion
        $script:Config = $Config

        $password = if ($State.EncryptPackage) { $State.EncryptPassword } else { $null }
        $result = Invoke-MigrationExportToDestination -Destination $Destination -Selection $Selection -Progress $prog `
            -EncryptPassword $password -Resume:$Resume
        $State.PackagePath = $result.PackagePath
        $State.UserData = $result.UserData
        $State.SystemSettings = $result.SystemSettings
        if ($password) { $State['EncryptedPackagePath'] = $result.PackagePath }
        $errors = @($result.Errors)
        if ($Destination.Type -eq 'LanReceive') { Disconnect-ReceiveSession -SharePath $Destination.Root }

        if ($Destination.Type -eq 'AdminShare') {
            $prog.Phase = 'Scheduling the restore on the target PC...'
            $task = Register-RemoteRestoreTask -ComputerName $State.NetworkTarget.ComputerName -Credential $State.NetworkTarget.Credential `
                -TargetUserName $State.NetworkTarget.TargetUserName -PackageName (Split-Path $result.PackagePath -Leaf)
            $State['RemoteRestoreLaunched'] = $task.Registered
            $State['RemoteRestoreMessage'] = $task.Message
            Add-ProgressLog $prog "  $($task.Message)"
        }

        $prog.Phase = 'Export complete!'
        $prog.Percent = 100
        $prog.Done = $true
        return @{ Success = $true; Errors = $errors; PackagePath = $result.PackagePath }
    }) | Out-Null

    $handle = $ps.BeginInvoke()
    $ctx.Job = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
    # Register with $State so MainWindow cleanup can stop this on window close
    $State.ActiveJob = $ctx.Job

    # Track last log index so we only append new entries
    $ctx['LastLogIdx'] = 0

    # Timer-driven progress polling
    $State.OnTick = {
        param($s)
        $p = $ctx.Progress

        # During copying the bar follows bytes moved; phase boundaries set the floor
        $pct = [int]$p.Percent
        if ($p.BytesTotal -gt 0 -and $pct -lt 80) {
            $pct = [Math]::Max($pct, [int](5 + 75 * [Math]::Min(1.0, $p.BytesDone / $p.BytesTotal)))
        }
        if ($pct -gt $ui.Progress.Value) {
            $ui.Progress.Value = $pct
            $ui.Percent.Text = "$pct%"
        }
        if ($p.Phase) { $ui.Phase.Text = $p.Phase }
        if ($p.Item) { $ui.Current.Text = $p.Item }
        if ($ui.Rate) { $ui.Rate.Text = & $formatRate -BytesDone $p.BytesDone -BytesTotal $p.BytesTotal -StartedUtc $p.StartedUtc }

        # Append new log entries
        $logCount = $p.Log.Count
        if ($logCount -gt $ctx.LastLogIdx) {
            for ($i = $ctx.LastLogIdx; $i -lt $logCount; $i++) {
                $ui.Log.AppendText("$($p.Log[$i])`r`n")
            }
            $ui.Log.ScrollToEnd()
            $ctx.LastLogIdx = $logCount
        }

        # Check for completion
        $job = $ctx.Job
        if ($job -and $job.Handle.IsCompleted) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                if ($job.PowerShell.HadErrors -and -not $result) {
                    throw $job.PowerShell.Streams.Error[0].Exception
                }
                $ui.Title.Text = "Export Complete!"
                $ui.Phase.Text = "Your migration package is ready."
                $ui.Progress.Value = 100
                $ui.Percent.Text = "100%"
                $ui.Current.Text = "$($s.PackagePath)"
                $s.BtnNext.IsEnabled = $true
                $s.BtnNext.Content = "Next"
                if ($result -and $result.Errors -and $result.Errors.Count -gt 0) {
                    $ui.Log.AppendText("Completed with $($result.Errors.Count) warning(s)`r`n")
                    foreach ($err in $result.Errors) {
                        $ui.Log.AppendText("  WARNING: $err`r`n")
                    }
                    $ui.Log.ScrollToEnd()
                }
            } catch {
                $ui.Title.Text = "Export Failed"
                $ui.Phase.Text = $_.Exception.Message
                try { $ui.Progress.Foreground = $Page.FindResource('ErrorBrush') } catch {}
                $s.BtnBack.IsEnabled = $true
            } finally {
                try {
                    $job.PowerShell.Dispose()
                    $job.Runspace.Close()
                    $job.Runspace.Dispose()
                } catch {}
                $ctx.Job = $null
                $s.ActiveJob = $null
                $s.OnTick = $null
            }
        }
    }.GetNewClosure()
}
