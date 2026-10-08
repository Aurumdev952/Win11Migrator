<#
========================================================================================================
    Title:          Win11Migrator - Import Progress Page
    Filename:       ImportProgressPage.ps1
    Description:    Displays real-time progress during the migration package import and restoration process.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ImportProgressPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $ui = @{
        Title      = $Page.FindName('txtImportTitle')
        Phase      = $Page.FindName('txtImportPhase')
        Progress   = $Page.FindName('progressImport')
        Percent    = $Page.FindName('txtImportPercent')
        Current    = $Page.FindName('txtCurrentImportItem')
        Rate       = $Page.FindName('txtImportRate')
        Success    = $Page.FindName('txtSuccessCount')
        Failed     = $Page.FindName('txtFailedCount')
        Remaining  = $Page.FindName('txtRemainingCount')
        Log        = $Page.FindName('txtImportLog')
    }
    $formatRate = ${function:Format-TransferRate}

    $State.BtnNext.IsEnabled = $false
    $State.BtnBack.IsEnabled = $false

    $totalItems = @($State.Manifest.Apps).Count + @($State.Manifest.UserData).Count +
                  @($State.Manifest.BrowserProfiles).Count + @($State.Manifest.SystemSettings).Count
    $ui.Remaining.Text = "$totalItems"

    $importProgress = if ($State.ImportProgress) { $State.ImportProgress } else {
        [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
    }
    $importProgress['Phase'] = 'Preparing...'
    $importProgress['Percent'] = 0
    $importProgress['Succeeded'] = 0
    $importProgress['Failed'] = 0
    $importProgress['TotalItems'] = $totalItems

    $ctx = @{ Job = $null; Progress = $importProgress; LastLogIdx = 0 }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('State', $State)
    $runspace.SessionStateProxy.SetVariable('prog', $importProgress)
    $runspace.SessionStateProxy.SetVariable('MigratorRoot', $State.MigratorRoot)
    $runspace.SessionStateProxy.SetVariable('Config', $State.Config)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        foreach ($core in 'Initialize-Environment', 'Write-MigrationLog', 'ConvertTo-MigrationManifest', 'Read-MigrationManifest', 'Invoke-WithRetry',
                          'Invoke-Robocopy', 'Get-MigrationExclusions', 'Get-PackageFingerprint', 'New-RollbackSnapshot',
                          'Get-OSMigrationContext', 'Convert-CrossOSSettings', 'Invoke-MigrationImport') {
            . (Join-Path $MigratorRoot "Core\$core.ps1")
        }
        foreach ($module in 'AppDiscovery', 'AppInstaller', 'UserData', 'BrowserProfiles', 'SystemSettings', 'AppProfiles', 'USMT') {
            Get-ChildItem (Join-Path $MigratorRoot "Modules\$module\*.ps1") -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
        }
        Get-ChildItem (Join-Path $MigratorRoot "Reports\*.ps1") | ForEach-Object { . $_.FullName }
        $script:MigratorRoot = $MigratorRoot
        $script:Config = $Config

        # Read the manifest here: objects built from the page's class definitions do not bind to this
        # runspace's [BrowserProfile], [SystemSetting] or [MigrationManifest] parameters
        $manifest = Read-MigrationManifest -ManifestPath (Join-Path $State.PackagePath 'manifest.json')
        $result = Invoke-MigrationImport -PackagePath $State.PackagePath -Manifest $manifest -Progress $prog `
            -AppWorker $State.AppWorker -MoveFromPackage:([bool]$State.MoveFromPackage)
        $State.AppWorker = $null
        $State['CompletionReportPath'] = $result.CompletionReportPath
        $State['ManualReportPath'] = $result.ManualReportPath
        $State['RollbackSnapshotPath'] = $result.RollbackSnapshotPath
        $State.Manifest = $manifest
        $State.Apps = $manifest.Apps
        $State.UserData = $manifest.UserData

        try {
            @{
                phase     = 'complete'
                percent   = 100
                succeeded = $result.Succeeded
                failed    = $result.Failed
                errors    = $result.Errors
                timestamp = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content (Join-Path $result.WorkPath "progress.json") -Encoding UTF8
        } catch {}

        $prog.Done = $true
        return $result
    }) | Out-Null

    $handle = $ps.BeginInvoke()
    $ctx.Job = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
    # Register with $State so MainWindow cleanup can stop this on window close
    $State.ActiveJob = $ctx.Job

    $State.OnTick = {
        param($s)
        $p = $ctx.Progress

        # While apps install alongside the file restore, the bar tracks the average of both
        $pct = [int]$p.Percent
        if ($p.Parallel) {
            $dataFrac = if ($p.BytesTotal -gt 0) { [Math]::Min(1.0, $p.BytesDone / $p.BytesTotal) } else { 1.0 }
            $appFrac = if ($p.AppsTotal -gt 0) { [Math]::Min(1.0, $p.AppsDone / $p.AppsTotal) } else { 1.0 }
            $pct = [Math]::Max($pct, [int](3 + 70 * ($dataFrac + $appFrac) / 2))
        }
        if ($pct -gt $ui.Progress.Value) {
            $ui.Progress.Value = $pct
            $ui.Percent.Text = "$pct%"
        }
        if ($p.Phase) { $ui.Phase.Text = $p.Phase }
        $current = @()
        if ($p.Item) { $current += $p.Item }
        if ($p.Parallel -and $p.AppsTotal -gt 0) { $current += "apps $($p.AppsDone) of $($p.AppsTotal)" }
        $ui.Current.Text = $current -join '   |   '
        if ($ui.Rate) { $ui.Rate.Text = & $formatRate -BytesDone $p.BytesDone -BytesTotal $p.BytesTotal -StartedUtc $p.StartedUtc }
        $ui.Success.Text = "$($p.Succeeded)"
        $ui.Failed.Text = "$($p.Failed)"
        $ui.Remaining.Text = "$([Math]::Max(0, [int]$p.TotalItems - [int]$p.Succeeded - [int]$p.Failed))"

        $logCount = $p.Log.Count
        if ($logCount -gt $ctx.LastLogIdx) {
            for ($i = $ctx.LastLogIdx; $i -lt $logCount; $i++) {
                $ui.Log.AppendText("$($p.Log[$i])`r`n")
            }
            $ui.Log.ScrollToEnd()
            $ctx.LastLogIdx = $logCount
        }

        $job = $ctx.Job
        if ($job -and $job.Handle.IsCompleted) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                if ($job.PowerShell.HadErrors -and -not $result) {
                    throw $job.PowerShell.Streams.Error[0].Exception
                }
                $result = @($result)[-1]
                $ui.Title.Text = "Import Complete!"
                $ui.Phase.Text = "Your migration is finished."
                $ui.Progress.Value = 100
                $ui.Percent.Text = "100%"
                $ui.Current.Text = ""
                $ui.Success.Text = "$($result.Succeeded)"
                $ui.Failed.Text = "$($result.Failed)"
                $ui.Remaining.Text = "0"
                $s.BtnNext.IsEnabled = $true
                $s.BtnNext.Content = "Next"
                if ($result.Errors -and $result.Errors.Count -gt 0) {
                    $ui.Log.AppendText("Completed with $($result.Errors.Count) warning(s)`r`n")
                    foreach ($err in $result.Errors) {
                        $ui.Log.AppendText("  WARNING: $err`r`n")
                    }
                    $ui.Log.ScrollToEnd()
                }
            } catch {
                $ui.Title.Text = "Import Failed"
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
