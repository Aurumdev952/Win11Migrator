<#
========================================================================================================
    Title:          Win11Migrator - Storage Target Selection Page
    Filename:       StorageSelectionPage.ps1
    Description:    Lets users choose a storage target (USB drive, OneDrive, or Google Drive) for the migration package.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-StorageSelectionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store controls in hashtable for closure access
    $ui = @{
        CardUSB       = $Page.FindName('cardUSB')
        TxtUSBStatus  = $Page.FindName('txtUSBStatus')
        CboUSBDrives  = $Page.FindName('cboUSBDrives')
        CardOneDrive  = $Page.FindName('cardOneDrive')
        TxtODStatus   = $Page.FindName('txtOneDriveStatus')
        TxtODPath     = $Page.FindName('txtOneDrivePath')
        CardGDrive    = $Page.FindName('cardGoogleDrive')
        TxtGDStatus   = $Page.FindName('txtGDriveStatus')
        TxtGDPath     = $Page.FindName('txtGDrivePath')
        CardNetShare  = $Page.FindName('cardNetworkShare')
        TxtNetPath    = $Page.FindName('txtNetworkPath')
        CardCustom    = $Page.FindName('cardCustom')
        BtnBrowse     = $Page.FindName('btnBrowse')
        CardNetDirect = $Page.FindName('cardNetworkDirect')
        CardLan       = $Page.FindName('cardLanReceive')
        ChkEncrypt    = $Page.FindName('chkEncrypt')
        PanelEncPwd   = $Page.FindName('panelEncryptPassword')
        TxtEncPwd     = $Page.FindName('txtEncryptPassword')
        TxtEncPwdConf = $Page.FindName('txtEncryptPasswordConfirm')
        TxtEncErr     = $Page.FindName('txtEncryptError')
    }

    $State.BtnNext.IsEnabled = $false

    # Card selection helper - highlights selected card
    $allCards = @($ui.CardUSB, $ui.CardOneDrive, $ui.CardGDrive, $ui.CardNetShare, $ui.CardCustom, $ui.CardNetDirect, $ui.CardLan) | Where-Object { $_ }

    # Detect USB drives
    Write-Host "[STORAGE] Detecting USB drives..." -ForegroundColor Cyan
    try {
        $usbDrives = Get-USBDrives
        if ($usbDrives -and @($usbDrives).Count -gt 0) {
            $usbDrives = @($usbDrives)
            if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "$($usbDrives.Count) USB drive(s) available" }
            if ($ui.CboUSBDrives) {
                $ui.CboUSBDrives.Visibility = 'Visible'
                foreach ($drive in $usbDrives) {
                    $label = "$($drive.DriveLetter) $($drive.Label) ($($drive.FreeGB) GB free)"
                    $ui.CboUSBDrives.Items.Add($label) | Out-Null
                }
                $ui.CboUSBDrives.SelectedIndex = 0
            }
            $State['USBDrives'] = $usbDrives
            Write-Host "[STORAGE] Found $($usbDrives.Count) USB drive(s)" -ForegroundColor Green
        } else {
            if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "No USB drives detected" }
            if ($ui.CardUSB) { $ui.CardUSB.Opacity = 0.5 }
            Write-Host "[STORAGE] No USB drives found" -ForegroundColor Yellow
        }
    } catch {
        if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "Unable to detect USB drives" }
        if ($ui.CardUSB) { $ui.CardUSB.Opacity = 0.5 }
        Write-Host "[STORAGE] USB detection error: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Detect cloud sync folders
    Write-Host "[STORAGE] Detecting cloud sync folders..." -ForegroundColor Cyan
    try {
        $cloudFolders = Find-CloudSyncFolders
        if ($cloudFolders.OneDrivePath -and (Test-Path $cloudFolders.OneDrivePath)) {
            if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "OneDrive sync folder found" }
            if ($ui.TxtODPath) { $ui.TxtODPath.Text = $cloudFolders.OneDrivePath }
            $State['OneDrivePath'] = $cloudFolders.OneDrivePath
            Write-Host "[STORAGE] OneDrive: $($cloudFolders.OneDrivePath)" -ForegroundColor Green
        } else {
            if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "OneDrive not available" }
            if ($ui.CardOneDrive) { $ui.CardOneDrive.Opacity = 0.5 }
        }

        if ($cloudFolders.GoogleDrivePath -and (Test-Path $cloudFolders.GoogleDrivePath)) {
            if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Google Drive sync folder found" }
            if ($ui.TxtGDPath) { $ui.TxtGDPath.Text = $cloudFolders.GoogleDrivePath }
            $State['GoogleDrivePath'] = $cloudFolders.GoogleDrivePath
            Write-Host "[STORAGE] Google Drive: $($cloudFolders.GoogleDrivePath)" -ForegroundColor Green
        } else {
            if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Google Drive not available" }
            if ($ui.CardGDrive) { $ui.CardGDrive.Opacity = 0.5 }
        }
    } catch {
        if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "Detection failed" }
        if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Detection failed" }
        Write-Host "[STORAGE] Cloud detection error: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Helper: remove NetworkTargetPage when switching away from NetworkDirect
    $removeNetPage = { if ($State.RemoveNetworkPage) { & $State.RemoveNetworkPage $State } }

    # Card click handlers
    $ui.CardUSB.Add_MouseLeftButtonUp({
        if ($ui.CardUSB.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardUSB.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $driveIdx = $ui.CboUSBDrives.SelectedIndex
            if ($driveIdx -ge 0 -and $State.USBDrives) {
                $State.StorageTarget = @{ Type = 'USB'; Path = "$($State.USBDrives[$driveIdx].DriveLetter)\" }
            }
        }
    }.GetNewClosure())

    $ui.CardOneDrive.Add_MouseLeftButtonUp({
        if ($ui.CardOneDrive.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardOneDrive.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $State.StorageTarget = @{ Type = 'OneDrive'; Path = $State.OneDrivePath }
        }
    }.GetNewClosure())

    $ui.CardGDrive.Add_MouseLeftButtonUp({
        if ($ui.CardGDrive.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardGDrive.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $State.StorageTarget = @{ Type = 'GoogleDrive'; Path = $State.GoogleDrivePath }
        }
    }.GetNewClosure())

    # Network Share card
    if ($ui.CardNetShare) {
        $ui.CardNetShare.Add_MouseLeftButtonUp({
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardNetShare.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $uncPath = $ui.TxtNetPath.Text.Trim()
            if ($uncPath -match '^\\\\[^\\]+\\[^\\]+') {
                $State.StorageTarget = @{ Type = 'NetworkShare'; Path = $uncPath }
                $State.BtnNext.IsEnabled = $true
            } else {
                $State.BtnNext.IsEnabled = $false
            }
        }.GetNewClosure())

        # Also validate on text change
        if ($ui.TxtNetPath) {
            $ui.TxtNetPath.Add_TextChanged({
                $uncPath = $ui.TxtNetPath.Text.Trim()
                if ($uncPath -match '^\\\\[^\\]+\\[^\\]+' -and $ui.CardNetShare.BorderBrush -eq $Page.FindResource('PrimaryBrush')) {
                    $State.StorageTarget = @{ Type = 'NetworkShare'; Path = $uncPath }
                    $State.BtnNext.IsEnabled = $true
                }
            }.GetNewClosure())
        }
    }

    $ui.CardCustom.Add_MouseLeftButtonUp({
        foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
        $ui.CardCustom.BorderBrush = $Page.FindResource('PrimaryBrush')
        & $removeNetPage
        # Don't enable Next until Browse dialog succeeds and sets StorageTarget
    }.GetNewClosure())

    $ui.BtnBrowse.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "Select a folder for the migration package"
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $State.StorageTarget = @{ Type = 'Custom'; Path = $dialog.SelectedPath }
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardCustom.BorderBrush = $Page.FindResource('PrimaryBrush')
            $State.BtnNext.IsEnabled = $true
        }
    }.GetNewClosure())

    # Direct Network Transfer card
    if ($ui.CardNetDirect) {
        $ui.CardNetDirect.Add_MouseLeftButtonUp({
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardNetDirect.BorderBrush = $Page.FindResource('PrimaryBrush')
            $State.StorageTarget = @{ Type = 'AdminShare'; Path = '' }
            # Insert NetworkTargetPage into the wizard so user is prompted for hostname/credentials
            if ($State.InsertNetworkPage) { & $State.InsertNetworkPage $State }
            $State.BtnNext.IsEnabled = $true
        }.GetNewClosure())
    }

    # --- Another PC on this network ---
    # Discovery and pairing run in a background runspace polled by the window timer, so the page never freezes.
    $State['LanUi'] = @{
        Card    = $ui.CardLan
        List    = $Page.FindName('lstReceivers')
        Host    = $Page.FindName('txtReceiverHost')
        Code    = $Page.FindName('txtLanPairingCode')
        Find    = $Page.FindName('btnFindReceivers')
        Connect = $Page.FindName('btnConnectReceiver')
        Status  = $Page.FindName('txtReceiverStatus')
        Cards   = $allCards
        Page    = $Page
        Job     = $null
    }
    $State['StartLanJob'] = {
        param([hashtable]$S, [string]$Kind, [hashtable]$Arguments)
        $lan = $S.LanUi
        if ($lan.Job) { return }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            param($Root, $Config, $Kind, $Arguments)
            . (Join-Path $Root 'Core\Write-MigrationLog.ps1')
            foreach ($f in 'ReceiveProtocol', 'Connect-ReceiveSession') { . (Join-Path $Root "Modules\NetworkTransfer\$f.ps1") }
            $script:Config = $Config
            if ($Kind -eq 'Find') { return @(Find-Receivers) }
            return Connect-ReceiveSession -Computer $Arguments.Computer -PairingCode $Arguments.Code
        }).AddArgument($S.MigratorRoot).AddArgument($S.Config).AddArgument($Kind).AddArgument($Arguments)
        $lan.Job = @{ Kind = $Kind; PowerShell = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs }
        $lan.Find.IsEnabled = $false
        $lan.Connect.IsEnabled = $false
    }
    $State.OnTick = {
        param($s)
        $lan = $s.LanUi
        $job = $lan.Job
        if (-not $job -or -not $job.Handle.IsCompleted) { return }
        $lan.Job = $null
        $lan.Find.IsEnabled = $true
        $lan.Connect.IsEnabled = $true
        try {
            $result = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.HadErrors -and $job.PowerShell.Streams.Error.Count -gt 0) {
                throw $job.PowerShell.Streams.Error[0].Exception
            }
            if ($job.Kind -eq 'Find') {
                $lan.List.Items.Clear()
                foreach ($r in @($result)) {
                    $null = $lan.List.Items.Add(("{0}  ({1}, {2:N0} GB free)" -f $r.Computer, $r.Address, ($r.FreeBytes / 1GB)))
                }
                $lan.List.Tag = @($result)
                $lan.List.Visibility = if (@($result).Count -gt 0) { 'Visible' } else { 'Collapsed' }
                $lan.Status.Text = if (@($result).Count -gt 0) { 'Select the new PC, then type its pairing code.' }
                                   else { "No PC is waiting. On the new PC choose 'Receive from another PC', or type its name or IP address." }
            } else {
                $target = @($result)[-1]
                $s.StorageTarget = $target
                foreach ($c in $lan.Cards) { $c.BorderBrush = $lan.Page.FindResource('BorderBrush') }
                $lan.Card.BorderBrush = $lan.Page.FindResource('PrimaryBrush')
                if ($s.RemoveNetworkPage) { & $s.RemoveNetworkPage $s }
                $lan.Status.Text = "Connected to $($target.Computer). Click Next to start sending."
                $s.BtnNext.IsEnabled = $true
            }
        } catch {
            $lan.Status.Text = $_.Exception.Message
        } finally {
            $job.PowerShell.Dispose()
            $job.Runspace.Dispose()
        }
    }

    if ($State.LanUi.Find) {
        $State.LanUi.Find.Add_Click({
            $State.LanUi.Status.Text = 'Looking for PCs waiting to receive...'
            & $State.StartLanJob $State 'Find' @{}
        }.GetNewClosure())
        $State.LanUi.List.Add_SelectionChanged({
            $picked = @($State.LanUi.List.Tag)[$State.LanUi.List.SelectedIndex]
            if ($picked) { $State.LanUi.Host.Text = $picked.Address }
        }.GetNewClosure())
        $State.LanUi.Connect.Add_Click({
            $lanHost = $State.LanUi.Host.Text.Trim()
            $lanCode = $State.LanUi.Code.Text.Trim()
            if (-not $lanHost -or -not $lanCode) {
                $State.LanUi.Status.Text = 'Enter the PC name (or pick one from the list) and the pairing code shown on it.'
                return
            }
            $State.LanUi.Status.Text = "Connecting to $lanHost..."
            & $State.StartLanJob $State 'Connect' @{ Computer = $lanHost; Code = $lanCode }
        }.GetNewClosure())
        & $State.StartLanJob $State 'Find' @{}
    }

    # Encryption checkbox
    if ($ui.ChkEncrypt) {
        $ui.ChkEncrypt.Add_Checked({
            $ui.PanelEncPwd.Visibility = 'Visible'
            $State['EncryptPackage'] = $true
        }.GetNewClosure())
        $ui.ChkEncrypt.Add_Unchecked({
            $ui.PanelEncPwd.Visibility = 'Collapsed'
            $State['EncryptPackage'] = $false
            $State['EncryptPassword'] = $null
        }.GetNewClosure())
    }

    # Validate encryption passwords on text change
    if ($ui.TxtEncPwd -and $ui.TxtEncPwdConf) {
        $validatePasswords = {
            if ($State.EncryptPackage) {
                $pwd1 = $ui.TxtEncPwd.Password
                $pwd2 = $ui.TxtEncPwdConf.Password
                if ([string]::IsNullOrEmpty($pwd1)) {
                    $ui.TxtEncErr.Text = "Password is required"
                    $State['EncryptPassword'] = $null
                } elseif ($pwd1.Length -lt 8) {
                    $ui.TxtEncErr.Text = "Password must be at least 8 characters"
                    $State['EncryptPassword'] = $null
                } elseif ($pwd1 -ne $pwd2) {
                    $ui.TxtEncErr.Text = "Passwords do not match"
                    $State['EncryptPassword'] = $null
                } else {
                    $ui.TxtEncErr.Text = ""
                    $State['EncryptPassword'] = ConvertTo-SecureString $pwd1 -AsPlainText -Force
                }
            }
        }.GetNewClosure()
        $ui.TxtEncPwd.Add_PasswordChanged($validatePasswords)
        $ui.TxtEncPwdConf.Add_PasswordChanged($validatePasswords)
    }

    Write-Host "[STORAGE] Storage selection page initialized" -ForegroundColor Cyan
}
