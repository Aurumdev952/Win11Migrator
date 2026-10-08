<#
========================================================================================================
    Title:          Win11Migrator - Application Discovery Pester Tests
    Filename:       AppDiscovery.Tests.ps1
    Description:    Pester test suite for the AppDiscovery module functions.
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
    Pester tests for App Discovery module.
#>


Describe "App Discovery Module Tests" {

    BeforeAll {
        $ProjectRoot = Split-Path $PSScriptRoot -Parent
        . "$ProjectRoot/Core/Initialize-Environment.ps1"
        . "$ProjectRoot/Core/Write-MigrationLog.ps1"
        $script:MigratorRoot = $ProjectRoot
        Get-ChildItem "$ProjectRoot/Modules/AppDiscovery/*.ps1" | ForEach-Object { . $_.FullName }
    }

    Context "Get-NormalizedAppName" {
        It "Should strip version numbers" {
            Get-NormalizedAppName -Name "VLC media player 3.0.18" | Should -Be "vlc media player"
        }

        It "Should strip architecture tags" {
            Get-NormalizedAppName -Name "7-Zip 23.01 (x64)" | Should -Be "7-zip"
        }

        It "Should strip edition markers" {
            Get-NormalizedAppName -Name "Visual Studio Community 2022" | Should -Be "visual studio"
        }

        It "Should handle empty strings" {
            Get-NormalizedAppName -Name "" | Should -Be ""
        }

        It "Should trim whitespace" {
            Get-NormalizedAppName -Name "  Notepad++  " | Should -Match "notepad\+\+"
        }
    }

    Context "Get-AppNameSimilarity" {
        It "Should return 1.0 for identical names" {
            $score = Get-AppNameSimilarity -Name1 "Google Chrome" -Name2 "Google Chrome"
            $score | Should -Be 1.0
        }

        It "Should return high similarity for close matches" {
            $score = Get-AppNameSimilarity -Name1 "Google Chrome" -Name2 "google chrome browser"
            $score | Should -BeGreaterThan 0.5
        }

        It "Should return low similarity for unrelated names" {
            $score = Get-AppNameSimilarity -Name1 "Google Chrome" -Name2 "Adobe Photoshop"
            $score | Should -BeLessThan 0.3
        }
    }

    Context "Config files" {
        It "Should load ExcludedApps.json" {
            $path = Join-Path $ProjectRoot "Config/ExcludedApps.json"
            Test-Path $path | Should -Be $true
            $data = Get-Content $path -Raw | ConvertFrom-Json
            $data.Count | Should -BeGreaterThan 0
        }

        It "Should load NiniteAppList.json" {
            $path = Join-Path $ProjectRoot "Config/NiniteAppList.json"
            Test-Path $path | Should -Be $true
            $data = Get-Content $path -Raw | ConvertFrom-Json
            $data | Should -Not -BeNullOrEmpty
        }

        It "Should load VendorDownloadUrls.json" {
            $path = Join-Path $ProjectRoot "Config/VendorDownloadUrls.json"
            Test-Path $path | Should -Be $true
            $data = Get-Content $path -Raw | ConvertFrom-Json
            $data | Should -Not -BeNullOrEmpty
        }

        It "Should load StoreAppCatalog.json" {
            $path = Join-Path $ProjectRoot "Config/StoreAppCatalog.json"
            Test-Path $path | Should -Be $true
            $data = Get-Content $path -Raw | ConvertFrom-Json
            $data | Should -Not -BeNullOrEmpty
        }
    }

    Context "Search-NinitePackage" {
        It "Should find Chrome in Ninite list" {
            $result = Search-NinitePackage -AppName "Google Chrome"
            $result.Found | Should -Be $true
            $result.PackageId | Should -Not -BeNullOrEmpty
        }

        It "Should not find non-existent app" {
            $result = Search-NinitePackage -AppName "NonExistentApp12345"
            $result.Found | Should -Be $false
        }
    }

    Context "Search-StorePackage" {
        It "Should find Netflix in Store catalog" {
            $result = Search-StorePackage -AppName "Netflix"
            $result.Found | Should -Be $true
        }
    }

    Context "Search-VendorDownload" {
        It "Should find Adobe Reader" {
            $result = Search-VendorDownload -AppName "Adobe Reader"
            $result.Found | Should -Be $true
            $result.DownloadUrl | Should -Not -BeNullOrEmpty
        }
    }
}
