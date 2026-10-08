<#
========================================================================================================
    Title:          Win11Migrator - Data Selection Page
    Filename:       DataSelectionPage.ps1
    Description:    Allows users to select user data folders, browser profiles, and system settings for migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-DataSelectionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store controls in hashtable for closure access
    $ui = @{
        PanelUserData    = $Page.FindName('panelUserData')
        PanelBrowsers    = $Page.FindName('panelBrowsers')
        PanelAppProfiles = $Page.FindName('panelAppProfiles')
        BtnAddFolder     = $Page.FindName('btnAddFolder')
        TotalSize        = $Page.FindName('txtTotalSize')
        ChkWiFi          = $Page.FindName('chkWiFi')
        ChkPrinters      = $Page.FindName('chkPrinters')
        ChkDrives        = $Page.FindName('chkDrives')
        ChkEnvVars       = $Page.FindName('chkEnvVars')
        ChkWinSettings   = $Page.FindName('chkWinSettings')
        ChkAccessibility = $Page.FindName('chkAccessibility')
        ChkRegional      = $Page.FindName('chkRegional')
        ChkVPN           = $Page.FindName('chkVPN')
        ChkCertificates  = $Page.FindName('chkCertificates')
        ChkODBC          = $Page.FindName('chkODBC')
        ChkFolderOptions = $Page.FindName('chkFolderOptions')
        ChkInputSettings = $Page.FindName('chkInputSettings')
        ChkPower         = $Page.FindName('chkPower')
        PanelCloudSync   = $Page.FindName('panelCloudSync')
        TxtCloudSyncInfo = $Page.FindName('txtCloudSyncInfo')
        BtnCloudCopyAll  = $Page.FindName('btnCloudCopyAll')
        BtnCloudSkipAll  = $Page.FindName('btnCloudSkipAll')
        PanelEFSWarning  = $Page.FindName('panelEFSWarning')
        TxtEFSWarning    = $Page.FindName('txtEFSWarning')
    }

    # Debug
    foreach ($key in $ui.Keys) {
        if (-not $ui[$key]) { Write-Host "[WARN] DataSelection control '$key' is null" -ForegroundColor Yellow }
    }

    # Track cloud sync toggle buttons so bulk actions can update them
    $cloudToggles = @{}

    # --- Folder sizing ---
    # Robocopy /L measures each folder with the active exclusions in a background runspace,
    # so the page stays responsive on large profiles. Results land in each item's SizeBytes.
    if (-not $State.DefaultExclusions) { $State['DefaultExclusions'] = Get-MigrationExclusions -Config $State.Config }
    if (-not $State.Exclusions) { $State['Exclusions'] = $State.DefaultExclusions }
    $sizeRows = [System.Collections.ArrayList]::new()
    $sizer = [hashtable]::Synchronized(@{ Generation = 0; Jobs = [System.Collections.ArrayList]::new() })
    $startSizing = {
        $sizer.Generation++
        $pendingItems = @($sizeRows | Where-Object { $null -eq $_.Item.SizeBytes } | ForEach-Object { $_.Item })
        if ($pendingItems.Count -eq 0) { return }
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            param($Items, $Exclusions, $Root, $Sizer, $Generation, $Config)
            . (Join-Path $Root 'Core\Invoke-Robocopy.ps1')
            $script:Config = $Config
            foreach ($it in $Items) {
                if ($Sizer.Generation -ne $Generation) { return }
                $bytes = try { [long](Measure-RobocopySource -Source $it.SourcePath -Exclusions $Exclusions).Bytes } catch { 0L }
                # A newer run (exclusions changed) owns the result now
                if ($Sizer.Generation -eq $Generation) { $it.SizeBytes = $bytes }
            }
        }).AddArgument($pendingItems).AddArgument($State.Exclusions).AddArgument($State.MigratorRoot).AddArgument($sizer).AddArgument($sizer.Generation).AddArgument($State.Config)
        $null = $sizer.Jobs.Add(@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs })
    }.GetNewClosure()

    # --- Detect cloud-synced folders ---
    $cloudItems = @()
    if ($State.UserData -and $State.UserData.Count -gt 0) {
        $cloudItems = @($State.UserData | Where-Object { $_.IsCloudSynced })
    }

    # Show cloud sync banner if any cloud folders detected
    if ($cloudItems.Count -gt 0 -and $ui.PanelCloudSync) {
        $ui.PanelCloudSync.Visibility = 'Visible'
        $providers = @($cloudItems | ForEach-Object { $_.CloudProvider } | Sort-Object -Unique)
        $providerLabel = ($providers -join ' & ')
        $ui.TxtCloudSyncInfo.Text = "$($cloudItems.Count) folder(s) are synced via $providerLabel. You can copy the data into the migration package, or skip copying and let $providerLabel re-sync on the new PC."

        # "Copy All Cloud Folders" button
        $ui.BtnCloudCopyAll.Add_Click({
            foreach ($item in $cloudItems) {
                $item.SkipCloudSync = $false
            }
            foreach ($key in $cloudToggles.Keys) {
                $cloudToggles[$key].Content = 'Copy'
                $cloudToggles[$key].Foreground = [System.Windows.Media.Brushes]::Green
            }
            Write-Host "[DATA] Cloud sync: user chose to COPY all cloud folders" -ForegroundColor Green
        }.GetNewClosure())

        # "Skip All" button
        $ui.BtnCloudSkipAll.Add_Click({
            foreach ($item in $cloudItems) {
                $item.SkipCloudSync = $true
            }
            foreach ($key in $cloudToggles.Keys) {
                $cloudToggles[$key].Content = 'Skip (Cloud Sync)'
                $cloudToggles[$key].Foreground = [System.Windows.Media.Brushes]::DodgerBlue
            }
            Write-Host "[DATA] Cloud sync: user chose to SKIP all cloud folders (re-sync)" -ForegroundColor Cyan
        }.GetNewClosure())
    }

    # --- User Data Folders ---
    # Scan produces hashtables: @{ Name='Desktop'; SourcePath='...'; ItemCount=5; Selected=$true }
    if ($State.UserData -and $State.UserData.Count -gt 0) {
        foreach ($item in $State.UserData) {
            # Build row: checkbox + optional cloud sync toggle
            $row = [System.Windows.Controls.Grid]::new()
            $col0 = [System.Windows.Controls.ColumnDefinition]::new()
            $col0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $col1 = [System.Windows.Controls.ColumnDefinition]::new()
            $col1.Width = [System.Windows.GridLength]::Auto
            $null = $row.ColumnDefinitions.Add($col0)
            $null = $row.ColumnDefinitions.Add($col1)
            $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)

            $cb = [System.Windows.Controls.CheckBox]::new()
            $cb.IsChecked = if ($item.Selected) { $true } else { $false }
            $label = "$($item.Name) ($($item.ItemCount) items)"
            if ($item.IsCloudSynced -and $item.CloudProvider) {
                $provName = if ($item.CloudProvider -eq 'GoogleDrive') { 'Google Drive' } else { $item.CloudProvider }
                $label = "$($item.Name) ($provName) ($($item.ItemCount) items)"
            } elseif ($item.IsOneDrive) {
                $label = "$($item.Name) (OneDrive) ($($item.ItemCount) items)"
            }
            if ($item.IsCustom) { $label = "$($item.Name) (Custom: $($item.SourcePath)) ($($item.ItemCount) items)" }
            $cb.Content = $label
            try { $cb.Style = $Page.FindResource('MigratorCheckBox') } catch {}
            $cb.Tag = $item
            if ($item -is [hashtable] -and -not $item.ContainsKey('SizeBytes')) { $item['SizeBytes'] = $null }
            $null = $sizeRows.Add(@{ Item = $item; CheckBox = $cb; Label = $label })
            $cb.Add_Checked({ $this.Tag.Selected = $true })
            $cb.Add_Unchecked({ $this.Tag.Selected = $false })
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            $row.Children.Add($cb) | Out-Null

            # Add cloud sync toggle button for cloud-synced folders
            if ($item.IsCloudSynced) {
                $toggleBtn = [System.Windows.Controls.Button]::new()
                $toggleBtn.FontSize = 11
                $toggleBtn.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
                $toggleBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
                $toggleBtn.VerticalAlignment = 'Center'
                $toggleBtn.Tag = $item
                if ($item.SkipCloudSync) {
                    $toggleBtn.Content = 'Skip (Cloud Sync)'
                    $toggleBtn.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                } else {
                    $toggleBtn.Content = 'Copy'
                    $toggleBtn.Foreground = [System.Windows.Media.Brushes]::Green
                }
                $toggleBtn.Add_Click({
                    $itm = $this.Tag
                    if ($itm.SkipCloudSync) {
                        $itm.SkipCloudSync = $false
                        $this.Content = 'Copy'
                        $this.Foreground = [System.Windows.Media.Brushes]::Green
                    } else {
                        $itm.SkipCloudSync = $true
                        $this.Content = 'Skip (Cloud Sync)'
                        $this.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                    }
                })
                [System.Windows.Controls.Grid]::SetColumn($toggleBtn, 1)
                $row.Children.Add($toggleBtn) | Out-Null
                $cloudToggles[$item.Name] = $toggleBtn
            }

            $ui.PanelUserData.Children.Add($row) | Out-Null
        }
    } else {
        $noData = [System.Windows.Controls.TextBlock]::new()
        $noData.Text = "No user data folders detected."
        $noData.Foreground = [System.Windows.Media.Brushes]::Gray
        $noData.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $ui.PanelUserData.Children.Add($noData) | Out-Null
    }

    # --- Add Folder button handler ---
    if ($ui.BtnAddFolder) {
        $ui.BtnAddFolder.Add_Click({
            $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dialog.Description = "Select a folder to include in migration"
            $dialog.ShowNewFolderButton = $false
            $result = $dialog.ShowDialog()
            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                $folderPath = $dialog.SelectedPath
                # Check for duplicates
                $duplicate = $State.UserData | Where-Object { $_.SourcePath -eq $folderPath }
                if ($duplicate) {
                    [System.Windows.MessageBox]::Show("This folder is already in the list.", "Duplicate Folder", 'OK', 'Information') | Out-Null
                    return
                }
                $folderName = [System.IO.Path]::GetFileName($folderPath)
                $topItems = @(Get-ChildItem $folderPath -ErrorAction SilentlyContinue -Force)
                $newItem = @{ Name = $folderName; SourcePath = $folderPath; ItemCount = $topItems.Count; Selected = $true; IsCustom = $true; IsOneDrive = $false; SizeBytes = $null }
                $State.UserData += $newItem

                # Add checkbox to panel
                $cb = [System.Windows.Controls.CheckBox]::new()
                $cb.IsChecked = $true
                $cb.Content = "$folderName (Custom: $folderPath) ($($topItems.Count) items)"
                try { $cb.Style = $Page.FindResource('MigratorCheckBox') } catch {}
                $cb.Tag = $newItem
                $cb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
                $cb.Add_Checked({ $this.Tag.Selected = $true }.GetNewClosure())
                $cb.Add_Unchecked({ $this.Tag.Selected = $false }.GetNewClosure())
                $ui.PanelUserData.Children.Add($cb) | Out-Null
                $null = $sizeRows.Add(@{ Item = $newItem; CheckBox = $cb; Label = $cb.Content })
                & $startSizing
                Write-Host "[DATA] Custom folder added: $folderPath ($($topItems.Count) items)" -ForegroundColor Green
            }
        }.GetNewClosure())
    }

    # --- Application Profiles ---
    if ($State.AppProfiles -and $State.AppProfiles.Count -gt 0) {
        foreach ($profile in $State.AppProfiles) {
            if (-not $profile.ContainsKey('Selected')) { $profile['Selected'] = $true }
            $cb = [System.Windows.Controls.CheckBox]::new()
            $cb.IsChecked = $profile.Selected
            $details = @()
            if ($profile.FileCount -gt 0) { $details += "$($profile.FileCount) files" }
            if ($profile.RegistryCount -gt 0) { $details += "$($profile.RegistryCount) registry" }
            $cb.Content = "$($profile.Name) [$($profile.Category)] ($($details -join ', '))"
            try { $cb.Style = $Page.FindResource('MigratorCheckBox') } catch {}
            $cb.Tag = $profile
            $cb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
            $cb.Add_Checked({ $this.Tag.Selected = $true })
            $cb.Add_Unchecked({ $this.Tag.Selected = $false })
            $ui.PanelAppProfiles.Children.Add($cb) | Out-Null
        }
    } else {
        $noProfiles = [System.Windows.Controls.TextBlock]::new()
        $noProfiles.Text = "No application profiles detected."
        $noProfiles.Foreground = [System.Windows.Media.Brushes]::Gray
        $noProfiles.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $ui.PanelAppProfiles.Children.Add($noProfiles) | Out-Null
    }

    # --- Browser Profiles ---
    # Scan produces hashtables: @{ Browser='Chrome'; ProfileName='Default'; Path='...' }
    if ($State.BrowserProfiles -and $State.BrowserProfiles.Count -gt 0) {
        # Add Selected property if missing
        foreach ($profile in $State.BrowserProfiles) {
            if (-not $profile.ContainsKey('Selected')) { $profile['Selected'] = $true }
        }

        foreach ($profile in $State.BrowserProfiles) {
            $cb = [System.Windows.Controls.CheckBox]::new()
            $cb.IsChecked = $profile.Selected
            $cb.Content = "$($profile.Browser) - $($profile.ProfileName)"
            try { $cb.Style = $Page.FindResource('MigratorCheckBox') } catch {}
            $cb.Tag = $profile
            $cb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
            $cb.Add_Checked({ $this.Tag.Selected = $true })
            $cb.Add_Unchecked({ $this.Tag.Selected = $false })
            $ui.PanelBrowsers.Children.Add($cb) | Out-Null
        }
    } else {
        $noBrowser = [System.Windows.Controls.TextBlock]::new()
        $noBrowser.Text = "No browser profiles detected."
        $noBrowser.Foreground = [System.Windows.Media.Brushes]::Gray
        $noBrowser.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $ui.PanelBrowsers.Children.Add($noBrowser) | Out-Null
    }

    # --- EFS Warning Banner ---
    if ($State.EFSWarning -and $ui.PanelEFSWarning) {
        $ui.PanelEFSWarning.Visibility = 'Visible'
        $ui.TxtEFSWarning.Text = $State.EFSWarning
    }

    # --- System Settings checkboxes ---
    $State['IncludeWiFi'] = $true
    $State['IncludePrinters'] = $true
    $State['IncludeDrives'] = $true
    $State['IncludeEnvVars'] = $true
    $State['IncludeWinSettings'] = $true
    $State['IncludeAccessibility'] = $true
    $State['IncludeRegional'] = $true
    $State['IncludeVPN'] = $true
    $State['IncludeCertificates'] = $true
    $State['IncludeODBC'] = $true
    $State['IncludeFolderOptions'] = $true
    $State['IncludeInputSettings'] = $true
    $State['IncludePower'] = $true

    # Annotate checkboxes with scanned counts
    if ($State.SystemSettings) {
        foreach ($setting in $State.SystemSettings) {
            switch ($setting.Category) {
                'WiFi'        { if ($ui.ChkWiFi) { $ui.ChkWiFi.Content = "WiFi Profiles ($($setting.Count) found)" } }
                'Printers'    { if ($ui.ChkPrinters) { $ui.ChkPrinters.Content = "Printer Configurations ($($setting.Count) found)" } }
                'MappedDrives'{ if ($ui.ChkDrives) { $ui.ChkDrives.Content = "Mapped Network Drives ($($setting.Count) found)" } }
                'EnvVars'     { if ($ui.ChkEnvVars) { $ui.ChkEnvVars.Content = "Environment Variables ($($setting.Count) found)" } }
            }
        }
    }

    if ($ui.ChkWiFi) {
        $ui.ChkWiFi.Add_Checked({ $State.IncludeWiFi = $true }.GetNewClosure())
        $ui.ChkWiFi.Add_Unchecked({ $State.IncludeWiFi = $false }.GetNewClosure())
    }
    if ($ui.ChkPrinters) {
        $ui.ChkPrinters.Add_Checked({ $State.IncludePrinters = $true }.GetNewClosure())
        $ui.ChkPrinters.Add_Unchecked({ $State.IncludePrinters = $false }.GetNewClosure())
    }
    if ($ui.ChkDrives) {
        $ui.ChkDrives.Add_Checked({ $State.IncludeDrives = $true }.GetNewClosure())
        $ui.ChkDrives.Add_Unchecked({ $State.IncludeDrives = $false }.GetNewClosure())
    }
    if ($ui.ChkEnvVars) {
        $ui.ChkEnvVars.Add_Checked({ $State.IncludeEnvVars = $true }.GetNewClosure())
        $ui.ChkEnvVars.Add_Unchecked({ $State.IncludeEnvVars = $false }.GetNewClosure())
    }
    if ($ui.ChkWinSettings) {
        $ui.ChkWinSettings.Add_Checked({ $State.IncludeWinSettings = $true }.GetNewClosure())
        $ui.ChkWinSettings.Add_Unchecked({ $State.IncludeWinSettings = $false }.GetNewClosure())
    }
    if ($ui.ChkAccessibility) {
        $ui.ChkAccessibility.Add_Checked({ $State.IncludeAccessibility = $true }.GetNewClosure())
        $ui.ChkAccessibility.Add_Unchecked({ $State.IncludeAccessibility = $false }.GetNewClosure())
    }
    if ($ui.ChkRegional) {
        $ui.ChkRegional.Add_Checked({ $State.IncludeRegional = $true }.GetNewClosure())
        $ui.ChkRegional.Add_Unchecked({ $State.IncludeRegional = $false }.GetNewClosure())
    }
    if ($ui.ChkVPN) {
        $ui.ChkVPN.Add_Checked({ $State.IncludeVPN = $true }.GetNewClosure())
        $ui.ChkVPN.Add_Unchecked({ $State.IncludeVPN = $false }.GetNewClosure())
    }
    if ($ui.ChkCertificates) {
        $ui.ChkCertificates.Add_Checked({ $State.IncludeCertificates = $true }.GetNewClosure())
        $ui.ChkCertificates.Add_Unchecked({ $State.IncludeCertificates = $false }.GetNewClosure())
    }
    if ($ui.ChkODBC) {
        $ui.ChkODBC.Add_Checked({ $State.IncludeODBC = $true }.GetNewClosure())
        $ui.ChkODBC.Add_Unchecked({ $State.IncludeODBC = $false }.GetNewClosure())
    }
    if ($ui.ChkFolderOptions) {
        $ui.ChkFolderOptions.Add_Checked({ $State.IncludeFolderOptions = $true }.GetNewClosure())
        $ui.ChkFolderOptions.Add_Unchecked({ $State.IncludeFolderOptions = $false }.GetNewClosure())
    }
    if ($ui.ChkInputSettings) {
        $ui.ChkInputSettings.Add_Checked({ $State.IncludeInputSettings = $true }.GetNewClosure())
        $ui.ChkInputSettings.Add_Unchecked({ $State.IncludeInputSettings = $false }.GetNewClosure())
    }
    if ($ui.ChkPower) {
        $ui.ChkPower.Add_Checked({ $State.IncludePower = $true }.GetNewClosure())
        $ui.ChkPower.Add_Unchecked({ $State.IncludePower = $false }.GetNewClosure())
    }

    # --- Exclusion editor ---
    # The boxes hold the full list (defaults included) so a default can be removed as well as added
    $excludeDirsBox = $Page.FindName('txtExcludeDirs')
    $excludeFilesBox = $Page.FindName('txtExcludeFiles')
    if ($excludeDirsBox -and $excludeFilesBox) {
        $showExclusions = {
            param($ex)
            $excludeDirsBox.Text = ($ex.Directories -join "`r`n")
            $excludeFilesBox.Text = ($ex.Files -join "`r`n")
        }.GetNewClosure()
        & $showExclusions $State.Exclusions

        $applyExclusions = {
            param($ex)
            $State['Exclusions'] = $ex
            foreach ($row in $sizeRows) { $row.Item.SizeBytes = $null }
            & $startSizing
        }.GetNewClosure()

        $btnApply = $Page.FindName('btnApplyExclusions')
        if ($btnApply) {
            $btnApply.Add_Click({
                $split = { param($text) @($text -split "[\r\n,;]+" | ForEach-Object { $_.Trim().TrimEnd('\', '/') } | Where-Object { $_ }) }
                & $applyExclusions @{ Directories = (& $split $excludeDirsBox.Text); Files = (& $split $excludeFilesBox.Text) }
            }.GetNewClosure())
        }
        $btnReset = $Page.FindName('btnResetExclusions')
        if ($btnReset) {
            $btnReset.Add_Click({
                & $applyExclusions $State.DefaultExclusions
                & $showExclusions $State.DefaultExclusions
            }.GetNewClosure())
        }
    }

    # --- Sizes and total, refreshed by the window timer while sizing runs ---
    $State.OnTick = {
        param($s)
        $total = 0L
        $measuring = $false
        foreach ($row in $sizeRows) {
            $bytes = $row.Item.SizeBytes
            $sizeText = if ($null -eq $bytes) { $measuring = $true; 'measuring...' }
                        elseif ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) }
                        else { '{0:N0} MB' -f ($bytes / 1MB) }
            $text = "$($row.Label) - $sizeText"
            if ($row.CheckBox.Content -ne $text) { $row.CheckBox.Content = $text }
            if ($null -ne $bytes -and $row.Item.Selected -and -not $row.Item.SkipCloudSync) { $total += $bytes }
        }
        if ($ui.TotalSize) {
            $folders = @($sizeRows | Where-Object { $_.Item.Selected }).Count
            $suffix = if ($measuring) { ' (still measuring)' } else { '' }
            $ui.TotalSize.Text = ('{0} folders selected, {1:N1} GB to copy{2}' -f $folders, ($total / 1GB), $suffix)
        }
        foreach ($job in @($sizer.Jobs)) {
            if ($job.Handle.IsCompleted) {
                try { $job.PowerShell.EndInvoke($job.Handle) } catch {}
                $job.PowerShell.Dispose()
                $job.Runspace.Dispose()
                $sizer.Jobs.Remove($job)
            }
        }
    }.GetNewClosure()
    & $startSizing

    # --- Migration Profile support ---
    # If a profile is loaded, apply its selections
    if ($State.MigrationProfile) {
        $profile = $State.MigrationProfile
        # Apply UserData folder selections
        if ($profile.UserData -and $profile.UserData.Folders) {
            foreach ($item in $State.UserData) {
                $item.Selected = $item.Name -in $profile.UserData.Folders
            }
        }
        # Apply system settings
        if ($profile.SystemSettings) {
            if ($ui.ChkWiFi -and $null -ne $profile.SystemSettings.WiFi) {
                $ui.ChkWiFi.IsChecked = $profile.SystemSettings.WiFi
                $State.IncludeWiFi = $profile.SystemSettings.WiFi
            }
            if ($ui.ChkPrinters -and $null -ne $profile.SystemSettings.Printers) {
                $ui.ChkPrinters.IsChecked = $profile.SystemSettings.Printers
                $State.IncludePrinters = $profile.SystemSettings.Printers
            }
            if ($ui.ChkDrives -and $null -ne $profile.SystemSettings.MappedDrives) {
                $ui.ChkDrives.IsChecked = $profile.SystemSettings.MappedDrives
                $State.IncludeDrives = $profile.SystemSettings.MappedDrives
            }
            if ($ui.ChkEnvVars -and $null -ne $profile.SystemSettings.EnvVars) {
                $ui.ChkEnvVars.IsChecked = $profile.SystemSettings.EnvVars
                $State.IncludeEnvVars = $profile.SystemSettings.EnvVars
            }
            if ($ui.ChkWinSettings -and $null -ne $profile.SystemSettings.WindowsSettings) {
                $ui.ChkWinSettings.IsChecked = $profile.SystemSettings.WindowsSettings
                $State.IncludeWinSettings = $profile.SystemSettings.WindowsSettings
            }
            if ($ui.ChkAccessibility -and $null -ne $profile.SystemSettings.Accessibility) {
                $ui.ChkAccessibility.IsChecked = $profile.SystemSettings.Accessibility
                $State.IncludeAccessibility = $profile.SystemSettings.Accessibility
            }
            if ($ui.ChkRegional -and $null -ne $profile.SystemSettings.Regional) {
                $ui.ChkRegional.IsChecked = $profile.SystemSettings.Regional
                $State.IncludeRegional = $profile.SystemSettings.Regional
            }
            if ($ui.ChkVPN -and $null -ne $profile.SystemSettings.VPN) {
                $ui.ChkVPN.IsChecked = $profile.SystemSettings.VPN
                $State.IncludeVPN = $profile.SystemSettings.VPN
            }
            if ($ui.ChkCertificates -and $null -ne $profile.SystemSettings.Certificates) {
                $ui.ChkCertificates.IsChecked = $profile.SystemSettings.Certificates
                $State.IncludeCertificates = $profile.SystemSettings.Certificates
            }
            if ($ui.ChkODBC -and $null -ne $profile.SystemSettings.ODBC) {
                $ui.ChkODBC.IsChecked = $profile.SystemSettings.ODBC
                $State.IncludeODBC = $profile.SystemSettings.ODBC
            }
            if ($ui.ChkFolderOptions -and $null -ne $profile.SystemSettings.FolderOptions) {
                $ui.ChkFolderOptions.IsChecked = $profile.SystemSettings.FolderOptions
                $State.IncludeFolderOptions = $profile.SystemSettings.FolderOptions
            }
            if ($ui.ChkInputSettings -and $null -ne $profile.SystemSettings.InputSettings) {
                $ui.ChkInputSettings.IsChecked = $profile.SystemSettings.InputSettings
                $State.IncludeInputSettings = $profile.SystemSettings.InputSettings
            }
            if ($ui.ChkPower -and $null -ne $profile.SystemSettings.Power) {
                $ui.ChkPower.IsChecked = $profile.SystemSettings.Power
                $State.IncludePower = $profile.SystemSettings.Power
            }
        }
        Write-Host "[DATA] Applied migration profile: $($profile.Name)" -ForegroundColor Green
    }

    Write-Host "[DATA] Page loaded: $($State.UserData.Count) folders, $($State.BrowserProfiles.Count) browsers, $($State.SystemSettings.Count) setting categories" -ForegroundColor Cyan
}
