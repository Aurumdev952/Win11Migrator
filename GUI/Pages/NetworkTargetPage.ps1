<#
========================================================================================================
    Title:          Win11Migrator - Network Target Selection Page
    Filename:       NetworkTargetPage.ps1
    Description:    Lets users discover and select a target computer for direct network migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-NetworkTargetPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # The tick handler reads its controls from $State instead of a closure, so it can call script functions
    $State['NetUi'] = @{
        Page              = $Page
        BtnScanNetwork    = $Page.FindName('btnScanNetwork')
        LstComputers      = $Page.FindName('lstComputers')
        TxtScanStatus     = $Page.FindName('txtScanStatus')
        TxtHostname       = $Page.FindName('txtHostname')
        TxtUsername       = $Page.FindName('txtUsername')
        TxtPassword       = $Page.FindName('txtPassword')
        TxtTargetUser     = $Page.FindName('txtTargetUser')
        BtnTestConnection = $Page.FindName('btnTestConnection')
        TxtConnStatus     = $Page.FindName('txtConnectionStatus')
        Job               = $null
    }
    $ui = $State.NetUi

    $State.BtnNext.IsEnabled = $false

    # Scanning and connection tests take seconds; they run in a runspace so the window stays responsive
    $State['StartNetJob'] = {
        param([hashtable]$S, [string]$Kind, [hashtable]$Arguments)
        $net = $S.NetUi
        if ($net.Job) { return }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            param($Root, $Config, $Kind, $Arguments)
            . (Join-Path $Root 'Core\Write-MigrationLog.ps1')
            foreach ($f in 'Find-NetworkComputers', 'Test-RemoteAccess', 'Register-RemoteRestoreTask') { . (Join-Path $Root "Modules\NetworkTransfer\$f.ps1") }
            $script:Config = $Config
            if ($Kind -eq 'Scan') { return @(Find-NetworkComputers -TimeoutMs 1000) }
            $test = Test-RemoteAccess -ComputerName $Arguments.ComputerName -Credential $Arguments.Credential -TimeoutMs 5000
            $target = $null
            if ($test.AdminShareAvailable) { $target = Connect-AdminShare -ComputerName $Arguments.ComputerName -Credential $Arguments.Credential }
            return @{ Test = $test; Target = $target }
        }).AddArgument($S.MigratorRoot).AddArgument($S.Config).AddArgument($Kind).AddArgument($Arguments)
        $net.Job = @{ Kind = $Kind; PowerShell = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs; Arguments = $Arguments }
        $net.BtnScanNetwork.IsEnabled = $false
        $net.BtnTestConnection.IsEnabled = $false
    }

    $State.OnTick = {
        param($s)
        $net = $s.NetUi
        $job = $net.Job
        if (-not $job -or -not $job.Handle.IsCompleted) { return }
        $net.Job = $null
        $net.BtnScanNetwork.IsEnabled = $true
        $net.BtnTestConnection.IsEnabled = $true
        try {
            $result = @($job.PowerShell.EndInvoke($job.Handle))
            if ($job.PowerShell.HadErrors -and $job.PowerShell.Streams.Error.Count -gt 0) { throw $job.PowerShell.Streams.Error[0].Exception }
            if ($job.Kind -eq 'Scan') {
                $net.LstComputers.Items.Clear()
                foreach ($pc in $result) {
                    $null = $net.LstComputers.Items.Add([PSCustomObject]@{
                        ComputerName = $pc.ComputerName; IPAddress = $pc.IPAddress; OS = $pc.OS; Online = $pc.Online
                    })
                }
                $net.TxtScanStatus.Text = if ($result.Count -gt 0) { "Found $($result.Count) computer(s)." } else { 'No computers found. Enter a hostname manually.' }
                return
            }

            $outcome = $result[-1]
            if ($outcome.Target) {
                $parts = @()
                if ($outcome.Test.Reachable) { $parts += 'Ping OK' }
                if ($outcome.Test.WinRMAvailable) { $parts += 'WinRM OK' }
                $parts += 'Admin share OK'
                $net.TxtConnStatus.Text = "Connected. [$($parts -join ', ')] The package will be written to C:\Win11Migrator on $($job.Arguments.ComputerName)."
                $net.TxtConnStatus.Foreground = $net.Page.FindResource('SuccessBrush')
                $s.StorageTarget = $outcome.Target
                $s.NetworkTarget = @{
                    ComputerName   = $job.Arguments.ComputerName
                    Credential     = $job.Arguments.Credential
                    TargetUserName = $job.Arguments.TargetUserName
                }
                $s.BtnNext.IsEnabled = $true
            } else {
                $net.TxtConnStatus.Text = "Connection failed. $($outcome.Test.ErrorMessage)"
                $net.TxtConnStatus.Foreground = $net.Page.FindResource('ErrorBrush')
                $s.BtnNext.IsEnabled = $false
            }
        } catch {
            $net.TxtConnStatus.Text = "Error: $($_.Exception.Message)"
            $net.TxtConnStatus.Foreground = $net.Page.FindResource('ErrorBrush')
        } finally {
            $job.PowerShell.Dispose()
            $job.Runspace.Dispose()
        }
    }

    $ui.BtnScanNetwork.Add_Click({
        $State.NetUi.TxtScanStatus.Text = 'Scanning network, please wait...'
        & $State.StartNetJob $State 'Scan' @{}
    }.GetNewClosure())

    $ui.LstComputers.Add_SelectionChanged({
        $selected = $State.NetUi.LstComputers.SelectedItem
        if ($selected) { $State.NetUi.TxtHostname.Text = $selected.ComputerName }
    }.GetNewClosure())

    $ui.BtnTestConnection.Add_Click({
        $net = $State.NetUi
        $hostname = $net.TxtHostname.Text.Trim()
        $username = $net.TxtUsername.Text.Trim()
        $password = $net.TxtPassword.Password
        $targetUser = $net.TxtTargetUser.Text.Trim()
        $problem = if (-not $hostname) { 'Please enter a hostname or IP address.' }
                   elseif (-not $username -or -not $password) { 'Please enter both username and password.' }
                   elseif (-not $targetUser) { 'Please enter the account that will sign in on the target PC.' }
        if ($problem) {
            $net.TxtConnStatus.Text = $problem
            $net.TxtConnStatus.Foreground = $net.Page.FindResource('ErrorBrush')
            return
        }
        $cred = [System.Management.Automation.PSCredential]::new($username, (ConvertTo-SecureString $password -AsPlainText -Force))
        $net.TxtConnStatus.Text = 'Testing connection...'
        $net.TxtConnStatus.Foreground = $net.Page.FindResource('TextSecondaryBrush')
        & $State.StartNetJob $State 'Test' @{ ComputerName = $hostname; Credential = $cred; TargetUserName = $targetUser }
    }.GetNewClosure())

    Write-MigrationLog -Message "Network target page initialized" -Level Info
}
