<#
========================================================================================================
    Title:          Win11Migrator - Core Module Pester Tests
    Filename:       Core.Tests.ps1
    Description:    Pester test suite for Core module functions including logging, retry, and manifest handling.
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
    Pester tests for Core module functions.
#>

# Import required modules
$ProjectRoot = Split-Path $PSScriptRoot -Parent

Describe "Core Module Tests" {

    BeforeAll {
        . "$ProjectRoot\Core\Initialize-Environment.ps1"
        . "$ProjectRoot\Core\Write-MigrationLog.ps1"
        . "$ProjectRoot\Core\Test-AdminPrivilege.ps1"
        . "$ProjectRoot\Core\Invoke-WithRetry.ps1"
        . "$ProjectRoot\Core\Get-DiskSpaceEstimate.ps1"
        . "$ProjectRoot\Core\ConvertTo-MigrationManifest.ps1"
        . "$ProjectRoot\Core\Read-MigrationManifest.ps1"
    }

    Context "Initialize-Environment" {
        It "Should use AppSettings.json as the runtime version source" {
            $config = Get-Content (Join-Path $ProjectRoot "Config\AppSettings.json") -Raw | ConvertFrom-Json
            $entryPoint = Get-Content (Join-Path $ProjectRoot "Win11Migrator.ps1") -Raw

            $entryPoint | Should -Match "AppSettings\.json"
            $entryPoint | Should -Not -Match "MigratorVersion\s*=\s*'\d+\.\d+\.\d+'"
            [version]$config.Version | Should -BeGreaterThan ([version]'0.0.0')
        }

        It "Should load config from AppSettings.json" {
            $config = Initialize-Environment -RootPath $ProjectRoot
            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Not -BeNullOrEmpty
            $config.RootPath | Should -Be $ProjectRoot
        }

        It "Should create log directory" {
            $config = Initialize-Environment -RootPath $ProjectRoot
            $logDir = Join-Path $ProjectRoot $config.LogDirectory
            Test-Path $logDir | Should -Be $true
        }

        It "Should throw if config file is missing" {
            { Initialize-Environment -RootPath "C:\NonExistent" } | Should -Throw
        }
    }

    Context "MigrationApp class" {
        It "Should create a new MigrationApp with defaults" {
            $app = [MigrationApp]::new()
            $app.Selected | Should -Be $true
            $app.Name | Should -BeNullOrEmpty
        }

        It "Should allow setting all properties" {
            $app = [MigrationApp]::new()
            $app.Name = "Test App"
            $app.Version = "1.0.0"
            $app.Publisher = "Test Publisher"
            $app.InstallMethod = "Winget"
            $app.PackageId = "Test.App"
            $app.MatchConfidence = 0.95
            $app.Name | Should -Be "Test App"
            $app.MatchConfidence | Should -Be 0.95
        }
    }

    Context "Write-MigrationLog" {
        It "Should enqueue log entries" {
            Clear-LogQueue
            Write-MigrationLog -Message "Test message" -Level Info
            $entries = Get-LogEntries
            $entries.Count | Should -BeGreaterThan 0
            $entries[0] | Should -Match "Test message"
        }

        It "Should include timestamp and level" {
            Clear-LogQueue
            Write-MigrationLog -Message "Level test" -Level Warning
            $entries = Get-LogEntries
            $entries[0] | Should -Match "\[Warning\]"
            $entries[0] | Should -Match "\d{4}-\d{2}-\d{2}"
        }
    }

    Context "Test-AdminPrivilege" {
        It "Should return a boolean" {
            $result = Test-AdminPrivilege
            $result | Should -BeOfType [bool]
        }
    }

    Context "Invoke-WithRetry" {
        It "Should succeed on first try" {
            $result = Invoke-WithRetry -ScriptBlock { "success" } -OperationName "Test"
            $result | Should -Be "success"
        }

        It "Should retry on failure and eventually succeed" {
            $script:attempt = 0
            $result = Invoke-WithRetry -ScriptBlock {
                $script:attempt++
                if ($script:attempt -lt 2) { throw "Transient error" }
                "recovered"
            } -MaxRetries 3 -DelaySeconds 0 -OperationName "RetryTest"
            $result | Should -Be "recovered"
        }

        It "Should throw after all retries exhausted" {
            { Invoke-WithRetry -ScriptBlock { throw "Persistent error" } -MaxRetries 2 -DelaySeconds 0 -OperationName "FailTest" } |
                Should -Throw
        }
    }

    Context "MigrationManifest round-trip" {
        It "Should serialize and deserialize a manifest" {
            $tempDir = Join-Path $env:TEMP "Win11Migrator_Test_$(Get-Random)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            try {
                # Create test data
                $app = [MigrationApp]::new()
                $app.Name = "Test App"
                $app.Version = "2.0"
                $app.InstallMethod = "Winget"
                $app.PackageId = "Test.App"

                $dataItem = [UserDataItem]::new()
                $dataItem.SourcePath = "C:\Users\Test\Documents"
                $dataItem.RelativePath = "Documents"
                $dataItem.Category = "Documents"
                $dataItem.SizeBytes = 1024

                # Serialize
                $manifestFile = ConvertTo-MigrationManifest -OutputPath $tempDir `
                    -Apps @($app) -UserData @($dataItem)

                Test-Path $manifestFile | Should -Be $true

                # Deserialize
                $loaded = Read-MigrationManifest -ManifestPath $manifestFile
                $loaded.Apps.Count | Should -Be 1
                $loaded.Apps[0].Name | Should -Be "Test App"
                $loaded.UserData.Count | Should -Be 1
                $loaded.SourceComputerName | Should -Be $env:COMPUTERNAME
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should throw on missing manifest" {
            { Read-MigrationManifest -ManifestPath "C:\NonExistent\manifest.json" } | Should -Throw
        }
    }

    Context "Get-DiskSpaceEstimate" {
        It "Should return an estimate object" {
            $item = [UserDataItem]::new()
            $item.SizeBytes = 1073741824  # 1 GB
            $item.Selected = $true

            $estimate = Get-DiskSpaceEstimate -UserData @($item) -BufferMB 100
            $estimate.EstimatedGB | Should -BeGreaterThan 1
            $estimate.BufferMB | Should -Be 100
        }
    }
}
