<#
========================================================================================================
    Title:          Win11Migrator - Configuration Validation
    Filename:       Test-MigrationConfig.ps1
    Description:    Validates all JSON config files on startup to catch misconfigurations early.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Validates all JSON configuration files required by Win11Migrator.

.DESCRIPTION
    Checks that each config file exists, is parseable JSON, and contains expected
    keys and value shapes. Returns a result object with errors (critical) and
    warnings (non-critical) rather than throwing, so callers can decide how to
    handle partial validity.

.PARAMETER RootPath
    Root path of the Win11Migrator installation (the folder containing Config/).

.OUTPUTS
    PSCustomObject with properties: Valid ([bool]), Errors ([string[]]), Warnings ([string[]]).
#>

function Test-MigrationConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $configDir = Join-Path $RootPath 'Config'

    # ------------------------------------------------------------------
    # Helper: Try to load a JSON file.  Returns $null and appends an
    # error when the file is missing or unparseable.
    # ------------------------------------------------------------------
    function Read-JsonConfig {
        param(
            [string]$FileName
        )

        $filePath = Join-Path $configDir $FileName

        if (-not (Test-Path $filePath)) {
            $errors.Add("Missing config file: $FileName")
            return $null
        }

        try {
            $raw = Get-Content -Path $filePath -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            return $parsed
        } catch {
            $errors.Add("Invalid JSON in $FileName - $($_.Exception.Message)")
            return $null
        }
    }

    function Test-StringArray {
        param($Value)
        if ($Value -isnot [System.Array]) { return $false }
        foreach ($v in $Value) { if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)) { return $false } }
        return $true
    }

    # ==================================================================
    #  1. AppSettings.json - required keys
    # ==================================================================
    $appSettings = Read-JsonConfig 'AppSettings.json'
    if ($appSettings) {
        $requiredKeys = @('LogDirectory', 'MigrationPackageDirectory')
        foreach ($key in $requiredKeys) {
            if (-not ($appSettings.PSObject.Properties.Name -contains $key)) {
                $errors.Add("AppSettings.json: missing required key '$key'")
            } elseif ([string]::IsNullOrWhiteSpace($appSettings.$key)) {
                $errors.Add("AppSettings.json: required key '$key' is empty")
            }
        }

        foreach ($key in 'ExcludeDirectories', 'ExcludeFilePatterns') {
            if ($appSettings.PSObject.Properties[$key] -and -not (Test-StringArray $appSettings.$key)) {
                $errors.Add("AppSettings.json: '$key' must be an array of non-empty strings")
            }
        }
        foreach ($key in 'RobocopyRetries', 'RobocopyWaitSeconds', 'MaxFileSizeMB') {
            if ($appSettings.PSObject.Properties[$key] -and -not ($appSettings.$key -is [ValueType] -and $appSettings.$key -ge 0)) {
                $errors.Add("AppSettings.json: '$key' must be a number of zero or more")
            }
        }
        if ($appSettings.PSObject.Properties['RobocopyThreadsByTarget']) {
            foreach ($prop in $appSettings.RobocopyThreadsByTarget.PSObject.Properties) {
                if ($prop.Name -notin 'Local', 'USB', 'Network', 'Cloud') {
                    $warnings.Add("AppSettings.json: RobocopyThreadsByTarget has unknown target kind '$($prop.Name)'")
                } elseif (-not ($prop.Value -is [ValueType] -and $prop.Value -ge 1 -and $prop.Value -le 128)) {
                    $errors.Add("AppSettings.json: RobocopyThreadsByTarget.$($prop.Name) must be between 1 and 128")
                }
            }
        }
    }

    # ==================================================================
    #  1b. MigrationProfiles/*.json - optional Exclusions block
    # ==================================================================
    $profileDir = Join-Path $configDir 'MigrationProfiles'
    if (Test-Path $profileDir) {
        foreach ($file in Get-ChildItem -Path $profileDir -Filter '*.json') {
            $migrationProfile = Read-JsonConfig "MigrationProfiles/$($file.Name)"
            if (-not $migrationProfile -or -not $migrationProfile.PSObject.Properties['Exclusions']) { continue }
            foreach ($key in 'Directories', 'Files') {
                $list = $migrationProfile.Exclusions.$key
                if ($null -ne $list -and -not (Test-StringArray $list)) {
                    $errors.Add("MigrationProfiles/$($file.Name): 'Exclusions.$key' must be an array of non-empty strings")
                }
            }
        }
    }

    # ==================================================================
    #  2. ExcludedApps.json - must be a JSON array
    # ==================================================================
    $excludedApps = Read-JsonConfig 'ExcludedApps.json'
    if ($excludedApps) {
        if ($excludedApps -isnot [System.Array]) {
            $errors.Add("ExcludedApps.json: expected a JSON array at root level")
        }
    }

    # ==================================================================
    #  3. StoreAppCatalog.json - StoreId + PackageFamilyName, duplicates
    # ==================================================================
    $storeCatalog = Read-JsonConfig 'StoreAppCatalog.json'
    if ($storeCatalog) {
        $storeIdMap = @{}   # StoreId -> list of app names that use it
        foreach ($prop in $storeCatalog.PSObject.Properties) {
            $appName = $prop.Name
            $entry   = $prop.Value

            if (-not $entry.StoreId) {
                $errors.Add("StoreAppCatalog.json: entry '$appName' is missing 'StoreId'")
            }
            if (-not $entry.PackageFamilyName) {
                $errors.Add("StoreAppCatalog.json: entry '$appName' is missing 'PackageFamilyName'")
            }

            # Track StoreIds for duplicate detection
            if ($entry.StoreId) {
                if (-not $storeIdMap.ContainsKey($entry.StoreId)) {
                    $storeIdMap[$entry.StoreId] = [System.Collections.Generic.List[string]]::new()
                }
                $storeIdMap[$entry.StoreId].Add($appName)
            }
        }

        # Report duplicate StoreIds
        foreach ($kvp in $storeIdMap.GetEnumerator()) {
            if ($kvp.Value.Count -gt 1) {
                $names = $kvp.Value -join ', '
                $warnings.Add("StoreAppCatalog.json: duplicate StoreId '$($kvp.Key)' shared by: $names")
            }
        }
    }

    # ==================================================================
    #  4. NiniteAppList.json - each value must be a non-empty string
    # ==================================================================
    $niniteList = Read-JsonConfig 'NiniteAppList.json'
    if ($niniteList) {
        foreach ($prop in $niniteList.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($prop.Value)) {
                $errors.Add("NiniteAppList.json: key '$($prop.Name)' has an empty or null value")
            }
        }
    }

    # ==================================================================
    #  5. VendorDownloadUrls.json - each entry needs a Url that looks
    #     like a URL
    # ==================================================================
    $vendorUrls = Read-JsonConfig 'VendorDownloadUrls.json'
    if ($vendorUrls) {
        foreach ($prop in $vendorUrls.PSObject.Properties) {
            $appName = $prop.Name
            $entry   = $prop.Value

            if (-not $entry.Url) {
                $errors.Add("VendorDownloadUrls.json: entry '$appName' is missing 'Url'")
            } elseif ($entry.Url -notmatch '^https?://') {
                $warnings.Add("VendorDownloadUrls.json: entry '$appName' has a Url that does not start with http:// or https://: $($entry.Url)")
            }
        }
    }

    # ==================================================================
    #  6. AppProfileCatalog.json - each entry needs Name, DisplayMatch,
    #     Category, Files, Registry
    # ==================================================================
    $profileCatalog = Read-JsonConfig 'AppProfileCatalog.json'
    if ($profileCatalog) {
        if ($profileCatalog -isnot [System.Array]) {
            $errors.Add("AppProfileCatalog.json: expected a JSON array at root level")
        } else {
            $requiredProfileKeys = @('Name', 'DisplayMatch', 'Category', 'Files', 'Registry')
            $index = 0
            foreach ($entry in $profileCatalog) {
                $entryLabel = if ($entry.Name) { $entry.Name } else { "index $index" }
                foreach ($key in $requiredProfileKeys) {
                    if (-not ($entry.PSObject.Properties.Name -contains $key)) {
                        $errors.Add("AppProfileCatalog.json: entry '$entryLabel' is missing required key '$key'")
                    }
                }
                $index++
            }
        }
    }

    # ==================================================================
    #  Build result
    # ==================================================================
    $valid = ($errors.Count -eq 0)

    $result = [PSCustomObject]@{
        Valid    = $valid
        Errors   = [string[]]$errors.ToArray()
        Warnings = [string[]]$warnings.ToArray()
    }

    # ------------------------------------------------------------------
    #  Log summary
    # ------------------------------------------------------------------
    if ($valid) {
        Write-MigrationLog -Message "Config validation passed ($($warnings.Count) warning(s))" -Level Success
    } else {
        Write-MigrationLog -Message "Config validation FAILED - $($errors.Count) error(s), $($warnings.Count) warning(s)" -Level Error
    }

    foreach ($err in $errors) {
        Write-MigrationLog -Message "  [Config Error] $err" -Level Error
    }
    foreach ($warn in $warnings) {
        Write-MigrationLog -Message "  [Config Warning] $warn" -Level Warning
    }

    return $result
}
