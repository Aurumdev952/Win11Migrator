<#
========================================================================================================
    Title:          Win11Migrator - Receive Page
    Filename:       ReceivePage.ps1
    Description:    Opens this PC to receive a package over the LAN, shows the pairing code, starts
                    application installs as soon as the manifest arrives, and hands the finished package
                    to the import page.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ReceivePage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # The tick handler reads its controls from $State instead of a closure, so it can call script functions
    $State['ReceiveUi'] = @{
        Title    = $Page.FindName('txtReceiveTitle')
        Code     = $Page.FindName('txtPairingCode')
        Identity = $Page.FindName('txtReceiverIdentity')
        Status   = $Page.FindName('txtReceiveStatus')
        Progress = $Page.FindName('progressReceive')
        Rate     = $Page.FindName('txtReceiveRate')
        Apps     = $Page.FindName('txtReceiveApps')
        Started  = $null
    }
    $ui = $State.ReceiveUi

    $State.BtnNext.IsEnabled = $false

    if (-not (Test-AdminPrivilege)) {
        $ui.Status.Text = "Receiving needs administrator rights to open a temporary network share. Close this window and start Win11Migrator with 'Run as administrator'."
        return
    }

    try {
        $session = Start-ReceiveSession
    } catch {
        $ui.Status.Text = "This PC could not be prepared to receive: $($_.Exception.Message)"
        return
    }
    $State['ReceiveSession'] = $session
    $ui.Code.Text = $session.Code
    $addresses = if ($session.Addresses) { $session.Addresses -join ', ' } else { 'no network address found' }
    $ui.Identity.Text = "This PC: $($session.Computer)   |   $addresses"
    $ui.Status.Text = "Waiting for the other PC to connect..."

    $State.OnTick = {
        param($s)
        $ui = $s.ReceiveUi
        $session = $s.ReceiveSession
        if (-not $session) { return }

        $incoming = Get-IncomingPackageState -IncomingPath $session.IncomingPath
        switch ($incoming.State) {
            'Waiting' { return }
            'Failed' {
                $ui.Status.Text = "The transfer from $($incoming.SourceComputer) stopped: $($incoming.Errors -join '; '). Start the export again on that PC; it resumes where it stopped."
                return
            }
        }

        if (-not $ui.Started) { $ui.Started = (Get-Date).ToUniversalTime() }
        $from = if ($incoming.SourceComputer) { $incoming.SourceComputer } else { 'the other PC' }
        $ui.Status.Text = "Receiving from $($from): $($incoming.Phase)"
        if ($incoming.BytesTotal -gt 0) {
            $ui.Progress.Value = [Math]::Min(100, 100 * $incoming.BytesDone / $incoming.BytesTotal)
        }
        $ui.Rate.Text = Format-TransferRate -BytesDone $incoming.BytesDone -BytesTotal $incoming.BytesTotal -StartedUtc $ui.Started

        # Apps start installing as soon as the manifest lands, while files are still arriving
        if ($incoming.ManifestReady -and -not $s.AppWorker) {
            try {
                $early = Read-MigrationManifest -ManifestPath (Join-Path $incoming.PackagePath 'manifest.json')
                $s['ImportProgress'] = [hashtable]::Synchronized(@{
                    Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                })
                $s['AppWorker'] = Start-AppInstallWorker -Apps $early.Apps -Progress $s.ImportProgress -Config $s.Config -MigratorRoot $s.MigratorRoot
            } catch {
                Write-MigrationLog -Message "Early app install could not start: $($_.Exception.Message)" -Level Warning
                $s['AppWorker'] = $null
            }
        }
        if ($s.ImportProgress -and $s.ImportProgress.AppsTotal -gt 0) {
            $ui.Apps.Text = "Installing apps while files arrive: $($s.ImportProgress.AppsDone) of $($s.ImportProgress.AppsTotal) done"
        }

        if ($incoming.State -eq 'Complete') {
            $s.OnTick = $null
            Stop-ReceiveSession -Session $session
            $s.ReceiveSession = $null
            try {
                $s.Manifest = Read-MigrationManifest -ManifestPath (Join-Path $incoming.PackagePath 'manifest.json')
            } catch {
                $ui.Status.Text = "The package arrived but its manifest could not be read: $($_.Exception.Message)"
                return
            }
            $s.PackagePath = $incoming.PackagePath
            $s['MoveFromPackage'] = $true
            $s.Mode = 'Import'
            $ui.Status.Text = "Everything arrived from $from. Restoring now..."
            & $s.NavigateTo ($s.CurrentPageIndex + 1) $s
        }
    }
}
