<#
========================================================================================================
    Title:          Win11Migrator - Integration Pester Tests
    Filename:       Integration.Tests.ps1
    Description:    End-to-end integration tests for the full migration pipeline.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Integration tests for Win11Migrator - tests the full export pipeline.
#>


Describe "Integration Tests" -Tag "Windows" {

    BeforeAll {
        $ProjectRoot = Split-Path $PSScriptRoot -Parent
        # Load all modules
        . "$ProjectRoot/Core/Initialize-Environment.ps1"
        . "$ProjectRoot/Core/Write-MigrationLog.ps1"
        . "$ProjectRoot/Core/Invoke-Robocopy.ps1"
        . "$ProjectRoot/Core/Get-MigrationExclusions.ps1"
        . "$ProjectRoot/Core/Test-AdminPrivilege.ps1"
        . "$ProjectRoot/Core/Invoke-WithRetry.ps1"
        . "$ProjectRoot/Core/Get-DiskSpaceEstimate.ps1"
        . "$ProjectRoot/Core/ConvertTo-MigrationManifest.ps1"
        . "$ProjectRoot/Core/Read-MigrationManifest.ps1"

        $script:MigratorRoot = $ProjectRoot
        $script:Config = Initialize-Environment -RootPath $ProjectRoot

        Get-ChildItem "$ProjectRoot/Modules/AppDiscovery/*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot/Modules/UserData/*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot/Modules/BrowserProfiles/*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot/Modules/SystemSettings/*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot/Modules/StorageTargets/*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot/Reports/*.ps1" | ForEach-Object { . $_.FullName }
    }

    Context "Full scan pipeline" {
        It "Should discover installed apps" {
            $apps = Get-InstalledApps -Config $script:Config
            $apps | Should -Not -BeNullOrEmpty
            $apps.Count | Should -BeGreaterThan 0
            Write-Host "  Found $($apps.Count) apps" -ForegroundColor Gray
        }

        It "Should detect user profile paths" {
            $paths = Get-UserProfilePaths
            $paths | Should -Not -BeNullOrEmpty
            $paths.Count | Should -BeGreaterThan 0
        }

        It "Should detect browser profiles" {
            $profiles = Get-BrowserProfilePaths
            # At minimum Edge should be present on Win11
            $profiles.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context "Manifest creation and validation" {
        It "Should create a valid manifest from scan results" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "Win11Migrator_IntTest_$(Get-Random)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            try {
                $apps = @()
                $app = [MigrationApp]::new()
                $app.Name = "Integration Test App"
                $app.Version = "1.0"
                $app.InstallMethod = "Manual"
                $apps += $app

                $userData = @()
                $dataItem = [UserDataItem]::new()
                $dataItem.SourcePath = $env:USERPROFILE
                $dataItem.RelativePath = "UserProfile"
                $dataItem.Category = "Documents"
                $dataItem.SizeBytes = 100
                $userData += $dataItem

                # Create manifest
                $manifestPath = ConvertTo-MigrationManifest -OutputPath $tempDir `
                    -Apps $apps -UserData $userData

                Test-Path $manifestPath | Should -Be $true

                # Validate JSON structure
                $json = Get-Content $manifestPath -Raw
                $parsed = $json | ConvertFrom-Json
                $parsed.Version | Should -Not -BeNullOrEmpty
                $parsed.SourceComputerName | Should -Be $env:COMPUTERNAME
                $parsed.Apps.Count | Should -Be 1
                $parsed.UserData.Count | Should -Be 1

                # Round-trip test
                $loaded = Read-MigrationManifest -ManifestPath $manifestPath
                $loaded.Apps[0].Name | Should -Be "Integration Test App"
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Storage target detection" {
        It "Should detect available USB drives without error" {
            { Get-USBDrives } | Should -Not -Throw
        }

        It "Should detect cloud sync folders without error" {
            { Find-CloudSyncFolders } | Should -Not -Throw
            $cloud = Find-CloudSyncFolders
            $cloud | Should -Not -BeNullOrEmpty
        }
    }

    Context "Report generation" {
        It "Should generate a manual install report" {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "Win11Migrator_Report_$(Get-Random)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            try {
                $app = [MigrationApp]::new()
                $app.Name = "Manual App"
                $app.Version = "1.0"
                $app.Publisher = "Test Publisher"
                $app.InstallMethod = "Manual"
                $app.InstallStatus = "Pending"

                $reportPath = New-ManualInstallReport -Apps @($app) -OutputPath $tempDir
                Test-Path $reportPath | Should -Be $true

                $html = Get-Content $reportPath -Raw
                $html | Should -Match "Manual App"
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Disk space estimation" {
        It "Should calculate estimates correctly" {
            $items = @()
            for ($i = 0; $i -lt 5; $i++) {
                $item = [UserDataItem]::new()
                $item.SizeBytes = 100MB
                $item.Selected = $true
                $items += $item
            }

            $estimate = Get-DiskSpaceEstimate -UserData $items -BufferMB 200
            $estimate.EstimatedMB | Should -BeGreaterThan 500
        }
    }

    Context "Project structure" {
        It "Should have all required directories" {
            $requiredDirs = @(
                'Config', 'Core', 'Modules\AppDiscovery', 'Modules\UserData',
                'Modules\BrowserProfiles', 'Modules\SystemSettings',
                'Modules\AppInstaller', 'Modules\StorageTargets',
                'GUI', 'GUI\Styles', 'GUI\Pages', 'GUI\Controls',
                'Reports', 'Reports\Templates', 'Tests'
            )
            foreach ($dir in $requiredDirs) {
                $fullPath = Join-Path $ProjectRoot $dir
                Test-Path $fullPath | Should -Be $true -Because "Directory $dir should exist"
            }
        }

        It "Should have all config files" {
            $configs = @(
                'Config\AppSettings.json',
                'Config\ExcludedApps.json',
                'Config\NiniteAppList.json',
                'Config\VendorDownloadUrls.json',
                'Config\StoreAppCatalog.json'
            )
            foreach ($file in $configs) {
                $fullPath = Join-Path $ProjectRoot $file
                Test-Path $fullPath | Should -Be $true -Because "$file should exist"
            }
        }

        It "Should have valid JSON in all config files" {
            Get-ChildItem (Join-Path $ProjectRoot "Config") -Filter "*.json" | ForEach-Object {
                $content = Get-Content $_.FullName -Raw
                { $content | ConvertFrom-Json } | Should -Not -Throw -Because "$($_.Name) should be valid JSON"
            }
        }
    }
}
