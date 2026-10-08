<#
========================================================================================================
    Title:          Win11Migrator - Export Engine
    Filename:       Invoke-MigrationExport.ps1
    Description:    The one export pipeline shared by the GUI, the CLI and network transfers. Writes the
                    package straight into its destination so data crosses each medium once.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:SettingsExportTable = @(
    @{ Flag = 'IncludeWiFi';          Label = 'WiFi profiles';          Func = 'Export-WiFiProfiles';          Sub = 'WiFi' }
    @{ Flag = 'IncludePrinters';      Label = 'Printer configs';        Func = 'Export-PrinterConfigs';        Sub = 'Printers' }
    @{ Flag = 'IncludeDrives';        Label = 'Mapped drives';          Func = 'Export-MappedDrives';          Sub = 'MappedDrives' }
    @{ Flag = 'IncludeEnvVars';       Label = 'Environment variables';  Func = 'Export-EnvironmentVariables';  Sub = 'EnvVars' }
    @{ Flag = 'IncludeWinSettings';   Label = 'Windows settings';       Func = 'Export-WindowsSettings';       Sub = 'WindowsSettings' }
    @{ Flag = 'IncludeAccessibility'; Label = 'Accessibility settings'; Func = 'Export-AccessibilitySettings'; Sub = 'Accessibility' }
    @{ Flag = 'IncludeRegional';      Label = 'Regional settings';      Func = 'Export-RegionalSettings';      Sub = 'Regional' }
    @{ Flag = 'IncludeVPN';           Label = 'VPN connections';        Func = 'Export-VPNConnections';        Sub = 'VPN' }
    @{ Flag = 'IncludeCertificates';  Label = 'User certificates';      Func = 'Export-UserCertificates';      Sub = 'Certificates' }
    @{ Flag = 'IncludeODBC';          Label = 'ODBC data sources';      Func = 'Export-ODBCSettings';          Sub = 'ODBC' }
    @{ Flag = 'IncludeFolderOptions'; Label = 'Folder options';         Func = 'Export-FolderOptions';         Sub = 'FolderOptions' }
    @{ Flag = 'IncludeInputSettings'; Label = 'Input settings';         Func = 'Export-InputSettings';         Sub = 'InputSettings' }
    @{ Flag = 'IncludePower';         Label = 'Power plan';             Func = 'Export-PowerSettings';         Sub = 'PowerPlan' }
)

function Get-AllSettingsFlags {
    $flags = @{}
    foreach ($exp in $script:SettingsExportTable) { $flags[$exp.Flag] = $true }
    return $flags
}

function New-MigrationPackageName {
    param([string]$ComputerName = $env:COMPUTERNAME)
    return "Win11Migration_$($ComputerName)_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

function Read-TransferStatus {
    param([Parameter(Mandatory)][string]$PackagePath)
    $file = Join-Path $PackagePath 'transfer.json'
    if (-not (Test-Path $file)) { return $null }
    try { return Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
}

function Write-TransferStatus {
    # Written via a temp file and rename so a reader on the other PC never sees half a document.
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][ValidateSet('InProgress', 'Complete', 'Failed')][string]$State,
        [string]$Phase = '',
        [long]$BytesTotal = 0,
        [long]$BytesDone = 0,
        [string[]]$Errors = @()
    )
    $status = [ordered]@{
        Version      = 1
        State        = $State
        Phase        = $Phase
        ComputerName = $env:COMPUTERNAME
        BytesTotal   = $BytesTotal
        BytesDone    = $BytesDone
        Errors       = @($Errors)
        UpdatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
    $final = Join-Path $PackagePath 'transfer.json'
    $temp = "$final.tmp"
    $status | ConvertTo-Json | Set-Content -Path $temp -Encoding UTF8
    Move-Item -Path $temp -Destination $final -Force
}

function Find-ResumablePackage {
    <#
    .SYNOPSIS
        Newest package from this computer under Root whose transfer never reached Complete.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    if (-not (Test-Path $Root)) { return $null }
    $candidates = Get-ChildItem -Path $Root -Directory -Filter "Win11Migration_$($ComputerName)_*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($dir in $candidates) {
        $status = Read-TransferStatus -PackagePath $dir.FullName
        if ($status -and $status.State -ne 'Complete') { return $dir.FullName }
    }
    return $null
}

function ConvertTo-UserDataItem {
    # The GUI scan produces hashtables; the CLI produces UserDataItem objects.
    param([Parameter(Mandatory)]$InputObject)
    if ($InputObject -is [UserDataItem]) { return $InputObject }
    $item = [UserDataItem]::new()
    $item.SourcePath    = $InputObject.SourcePath
    $item.RelativePath  = if ($InputObject.Name) { $InputObject.Name } else { $InputObject.RelativePath }
    $item.Category      = if ($InputObject.Name) { $InputObject.Name } else { $InputObject.Category }
    $item.Selected      = $true
    $item.IsCustom      = [bool]$InputObject.IsCustom
    $item.IsCloudSynced = [bool]$InputObject.IsCloudSynced
    $item.CloudProvider = if ($InputObject.CloudProvider) { $InputObject.CloudProvider } else { '' }
    $item.SkipCloudSync = [bool]$InputObject.SkipCloudSync
    $item.SizeBytes     = [long]$InputObject.SizeBytes
    if ($item.IsCustom) { $item.Category = 'Custom' }
    return $item
}

function ConvertTo-BrowserProfileItem {
    param([Parameter(Mandatory)]$InputObject)
    if ($InputObject -is [BrowserProfile]) { return $InputObject }
    $obj = [BrowserProfile]::new()
    $obj.Browser     = $InputObject.Browser
    $obj.ProfileName = $InputObject.ProfileName
    $obj.ProfilePath = if ($InputObject.ProfilePath) { $InputObject.ProfilePath } else { '' }
    $obj.Selected    = $true
    return $obj
}

function Resolve-UniqueRelativePath {
    # Two custom folders can share a leaf name ("Projects"); each needs its own package folder.
    param([UserDataItem[]]$Items)
    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        $base = $item.RelativePath
        $candidate = $base
        $n = 2
        while (-not $used.Add($candidate)) { $candidate = "$base ($n)"; $n++ }
        $item.RelativePath = $candidate
    }
}

function Invoke-MigrationExport {
    <#
    .SYNOPSIS
        Writes a complete migration package into PackagePath.
    .DESCRIPTION
        Re-running against the same PackagePath resumes: Robocopy skips files that are already
        identical, and every other phase is cheap and overwrites its own output.
        The manifest is written first (apps and inventory) so a receiving PC can begin
        installing applications while user data is still arriving, then rewritten at the end.
    .PARAMETER Selection
        Hashtable with Apps, UserData, BrowserProfiles, AppProfiles, SettingsFlags,
        IncludeAppData, UseUSMT and Exclusions.
    .PARAMETER Progress
        Synchronized hashtable: Phase, Percent, Item, Log, BytesTotal, BytesDone, Echo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][hashtable]$Selection,
        [ValidateSet('Local', 'USB', 'Network', 'Cloud')]
        [string]$TargetKind = 'Local',
        [hashtable]$Progress = [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
    )

    New-Item -Path $PackagePath -ItemType Directory -Force | Out-Null
    $errors = [System.Collections.Generic.List[string]]::new()
    $exclusions = if ($Selection.Exclusions) { $Selection.Exclusions } else { Get-MigrationExclusions }
    $settingsFlags = if ($Selection.SettingsFlags) { $Selection.SettingsFlags } else { Get-AllSettingsFlags }

    $userData = @(@($Selection.UserData) | Where-Object { $_ -and $_.Selected } | ForEach-Object { ConvertTo-UserDataItem $_ })
    Resolve-UniqueRelativePath -Items $userData
    $toCopy = @($userData | Where-Object { -not $_.SkipCloudSync })
    foreach ($skipped in @($userData | Where-Object { $_.SkipCloudSync })) { $skipped.ExportStatus = 'Skipped' }
    $browsers = @(@($Selection.BrowserProfiles) | Where-Object { $_ -and $_.Selected } | ForEach-Object { ConvertTo-BrowserProfileItem $_ })
    $apps = @(@($Selection.Apps) | Where-Object { $_ -and $_.Selected })
    $appProfiles = @(@($Selection.AppProfiles) | Where-Object { $_ -and $_.Selected })
    $settings = @()
    $usmtPresent = $false

    $Progress['BytesTotal'] = [long](($toCopy | Measure-Object -Property SizeBytes -Sum).Sum)
    $Progress['BytesDone'] = 0L
    $Progress['StartedUtc'] = (Get-Date).ToUniversalTime()

    $reportStatus = {
        param([string]$State = 'InProgress')
        try {
            Write-TransferStatus -PackagePath $PackagePath -State $State -Phase ([string]$Progress.Phase) `
                -BytesTotal ([long]$Progress.BytesTotal) -BytesDone ([long]$Progress.BytesDone) -Errors $errors.ToArray()
        } catch {
            Write-MigrationLog -Message "Could not update transfer.json: $($_.Exception.Message)" -Level Warning
        }
    }
    $setPhase = {
        param([string]$Phase, [int]$Percent)
        $Progress['Phase'] = $Phase
        $Progress['Percent'] = $Percent
        Add-ProgressLog $Progress "[$Phase]"
        & $reportStatus
    }
    $writeManifest = {
        param([bool]$Final)
        ConvertTo-MigrationManifest -OutputPath $PackagePath -Apps $apps -UserData $userData `
            -BrowserProfiles $browsers -SystemSettings $settings -AppProfiles $appProfiles `
            -Metadata @{
                Errors           = $errors.ToArray()
                Exclusions       = $exclusions
                ExportComplete   = $Final
                USMTStorePresent = $usmtPresent
            } | Out-Null
    }

    & $setPhase 'Writing initial manifest' 2
    try { & $writeManifest $false } catch { $errors.Add("Manifest: $($_.Exception.Message)") }

    if ($apps.Count -gt 0 -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        # A list a technician can feed to `winget import` if the automated reinstall is not used
        try {
            $appsDir = Join-Path $PackagePath 'Apps'
            New-Item -Path $appsDir -ItemType Directory -Force | Out-Null
            & winget export -o (Join-Path $appsDir 'winget-packages.json') --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        } catch {
            Add-ProgressLog $Progress "  [WARN] winget export: $($_.Exception.Message)"
        }
    }

    & $setPhase 'Exporting user data' 5
    if ($toCopy.Count -gt 0) {
        try {
            Export-UserProfile -Items $toCopy -OutputDirectory (Join-Path $PackagePath 'UserData') `
                -Exclusions $exclusions -TargetKind $TargetKind -Progress $Progress `
                -OnProgress { & $reportStatus } -PreserveACLs:([bool](Get-MigrationSetting $script:Config 'PreserveACLs' $false)) | Out-Null
            foreach ($failed in @($toCopy | Where-Object { $_.ExportStatus -eq 'Failed' })) {
                $errors.Add("UserData: $($failed.Category) failed to copy")
            }
            Add-ProgressLog $Progress "  Copied $(@($toCopy | Where-Object { $_.ExportStatus -eq 'Success' }).Count) of $($toCopy.Count) folders"
        } catch {
            $errors.Add("UserData: $($_.Exception.Message)")
        }
    }

    & $setPhase 'Exporting browser profiles' 80
    $browserDir = Join-Path $PackagePath 'BrowserProfiles'
    foreach ($bp in $browsers) {
        $Progress['Item'] = "$($bp.Browser) - $($bp.ProfileName)"
        $profileDir = Join-Path $browserDir "$($bp.Browser)_$($bp.ProfileName)"
        try {
            New-Item -Path $profileDir -ItemType Directory -Force | Out-Null
            switch ($bp.Browser) {
                'Chrome'  { Export-ChromeProfile -Profile $bp -OutputDirectory $profileDir | Out-Null }
                'Edge'    { Export-EdgeProfile -Profile $bp -OutputDirectory $profileDir | Out-Null }
                'Firefox' { Export-FirefoxProfile -Profile $bp -OutputDirectory $profileDir | Out-Null }
                'Brave'   { Export-BraveProfile -Profile $bp -OutputDirectory $profileDir | Out-Null }
            }
        } catch {
            $errors.Add("Browser $($bp.Browser)/$($bp.ProfileName): $($_.Exception.Message)")
        }
    }

    & $setPhase 'Exporting system settings' 84
    $settingsDir = Join-Path $PackagePath 'SystemSettings'
    foreach ($exp in $script:SettingsExportTable) {
        if (-not $settingsFlags[$exp.Flag]) { continue }
        $Progress['Item'] = $exp.Label
        try {
            $result = & $exp.Func -ExportPath (Join-Path $settingsDir $exp.Sub)
            if ($result) { $settings += $result }
        } catch {
            Add-ProgressLog $Progress "  [WARN] $($exp.Label): $($_.Exception.Message)"
        }
    }

    if ($Selection.UseUSMT) {
        & $setPhase 'Running USMT ScanState' 87
        try {
            $usmt = Test-USMTAvailability
            if ($usmt.Available) {
                $usmtStore = Join-Path $PackagePath 'USMTStore'
                New-Item -Path $usmtStore -ItemType Directory -Force | Out-Null
                $usmtXmls = @($usmt.MigAppXml, $usmt.MigDocsXml, $usmt.MigUserXml) | Where-Object { $_ -and (Test-Path $_) }
                $usmtResult = Invoke-USMTScanState -ScanStatePath $usmt.ScanStatePath -StorePath $usmtStore `
                    -MigrationXmls $usmtXmls -LogPath (Join-Path $PackagePath 'usmt_scanstate.log')
                $usmtPresent = [bool]$usmtResult.Success
                if (-not $usmtResult.Success) { Add-ProgressLog $Progress "  [WARN] USMT exit code $($usmtResult.ExitCode): $($usmtResult.ErrorMessage)" }
            }
        } catch {
            Add-ProgressLog $Progress "  [WARN] USMT: $($_.Exception.Message)"
        }
    }

    if ($Selection.IncludeAppData -ne $false) {
        & $setPhase 'Exporting AppData settings' 90
        try {
            $appDataItems = @(Export-AppDataSettings -OutputDirectory $PackagePath -Exclusions $exclusions -TargetKind $TargetKind -Progress $Progress)
            $userData = @($userData) + $appDataItems
        } catch {
            $errors.Add("AppData: $($_.Exception.Message)")
        }
    }

    if ($appProfiles.Count -gt 0) {
        & $setPhase 'Exporting application profiles' 94
        try {
            Export-AppProfiles -Profiles $appProfiles -OutputPath (Join-Path $PackagePath 'AppProfiles') | Out-Null
        } catch {
            $errors.Add("AppProfiles: $($_.Exception.Message)")
        }
    }

    & $setPhase 'Writing manifest' 97
    try { & $writeManifest $true } catch { $errors.Add("Manifest: $($_.Exception.Message)") }

    $Progress['Item'] = ''
    $Progress['Percent'] = 100

    return [PSCustomObject]@{
        PackagePath    = $PackagePath
        Errors         = $errors.ToArray()
        UserData       = $userData
        SystemSettings = $settings
    }
}

function Invoke-MigrationExportToDestination {
    <#
    .SYNOPSIS
        Runs the export into a resolved destination: resume detection, optional encryption,
        bundling the tool next to the package, and the final transfer status.
    .PARAMETER Destination
        Output of Resolve-ExportDestination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Destination,
        [Parameter(Mandatory)][hashtable]$Selection,
        [hashtable]$Progress = [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) }),
        [securestring]$EncryptPassword,
        [switch]$Resume
    )

    New-Item -Path $Destination.Root -ItemType Directory -Force | Out-Null

    if ($EncryptPassword -and $Destination.Type -eq 'LanReceive') {
        # The receiving PC restores a package folder as it arrives; the link is already private between two PCs
        Add-ProgressLog $Progress 'Encryption is skipped for direct PC-to-PC transfer.'
        $EncryptPassword = $null
    }

    $packagePath = $null
    if ($Resume -and -not $EncryptPassword) {
        $packagePath = Find-ResumablePackage -Root $Destination.Root
        if ($packagePath) { Add-ProgressLog $Progress "Resuming unfinished package $packagePath" }
    }
    if (-not $packagePath) {
        $name = New-MigrationPackageName
        $packagePath = if ($EncryptPassword) {
            Join-Path $script:Config.PackagePath $name
        } else {
            Join-Path $Destination.Root $name
        }
    }
    $Progress['PackagePath'] = $packagePath

    try {
        $result = Invoke-MigrationExport -PackagePath $packagePath -Selection $Selection -TargetKind $Destination.TargetKind -Progress $Progress
    } catch {
        # Tell a waiting receiver the transfer stopped instead of leaving it waiting
        try { Write-TransferStatus -PackagePath $packagePath -State Failed -Phase ([string]$Progress.Phase) -Errors @($_.Exception.Message) } catch { }
        throw
    }
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $result.Errors) { $errors.Add($e) }
    $output = $packagePath

    if ($EncryptPassword) {
        $Progress['Phase'] = 'Encrypting migration package'
        $encrypted = Join-Path $Destination.Root "$(Split-Path $packagePath -Leaf).w11mcrypt"
        $enc = Protect-MigrationPackage -PackagePath $packagePath -Password $EncryptPassword -OutputFile $encrypted
        if ($enc.Success) {
            $output = $enc.OutputFile
            Remove-Item -Path $packagePath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            $errors.Add("Encryption failed; the unencrypted package was kept at $packagePath")
        }
    }

    if ($Destination.CopyMigrator) {
        $Progress['Phase'] = 'Bundling Win11Migrator next to the package'
        try { Copy-MigratorToTarget -TargetBasePath $Destination.Root | Out-Null } catch { $errors.Add("Tool copy: $($_.Exception.Message)") }
    }

    if (-not $EncryptPassword) {
        $Progress['Phase'] = 'Export complete'
        Write-TransferStatus -PackagePath $packagePath -State 'Complete' -Phase 'Complete' `
            -BytesTotal ([long]$Progress.BytesTotal) -BytesDone ([long]$Progress.BytesDone) -Errors $errors.ToArray()
    }

    return [PSCustomObject]@{
        Success        = $true
        PackagePath    = $output
        Errors         = $errors.ToArray()
        UserData       = $result.UserData
        SystemSettings = $result.SystemSettings
    }
}
