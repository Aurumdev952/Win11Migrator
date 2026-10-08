#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for deciding which `winget list` rows can be reinstalled, and the install command line.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Modules/AppDiscovery/Get-WingetApps.ps1"
    $exportJson = @'
{ "Sources": [
    { "SourceDetails": { "Name": "winget" }, "Packages": [ { "PackageIdentifier": "Google.Chrome" }, { "PackageIdentifier": "Microsoft.VisualStudioCode" }, { "PackageIdentifier": "Microsoft.VisualStudio.2022.BuildTools" } ] },
    { "SourceDetails": { "Name": "msstore" }, "Packages": [ { "PackageIdentifier": "9NBLGGH4NNS1" } ] }
] }
'@
    $ids = ConvertFrom-WingetExport -Json $exportJson
}

Describe 'ConvertFrom-WingetExport' {
    It 'collects package IDs from every source' {
        $ids.Count | Should -Be 4
        $ids.Contains('9NBLGGH4NNS1') | Should -BeTrue
    }
}

Describe 'Resolve-WingetListId' {
    It 'keeps IDs winget can reinstall' {
        Resolve-WingetListId -ListedId 'Google.Chrome' -ListedSource 'winget' -InstallableIds $ids | Should -Be 'Google.Chrome'
    }

    It 'drops local registrations that no source can reinstall' {
        Resolve-WingetListId -ListedId 'ARP\Machine\X64\{1234}' -ListedSource '' -InstallableIds $ids | Should -BeNullOrEmpty
        Resolve-WingetListId -ListedId 'MSIX\Microsoft.Paint_11.2302' -ListedSource '' -InstallableIds $ids | Should -BeNullOrEmpty
    }

    It 'recovers a truncated ID whatever the ellipsis decoded to' -TestCases @(
        @{ Listed = "Microsoft.VisualStudio.2022.Bui$([char]0x2026)" }
        @{ Listed = 'Microsoft.VisualStudio.2022.Bui...' }
        @{ Listed = "Microsoft.VisualStudio.2022.Bui$([char]0x00E2)$([char]0x20AC)$([char]0x00A6)" }
    ) {
        Resolve-WingetListId -ListedId $Listed -ListedSource 'winget' -InstallableIds $ids | Should -Be 'Microsoft.VisualStudio.2022.BuildTools'
    }

    It 'refuses an ambiguous truncated ID' {
        Resolve-WingetListId -ListedId "Microsoft.Visual$([char]0x2026)" -ListedSource 'winget' -InstallableIds $ids | Should -BeNullOrEmpty
    }

    It 'without an export list, trusts only complete IDs that have a source' {
        Resolve-WingetListId -ListedId 'Google.Chrome' -ListedSource 'winget' -InstallableIds $null | Should -Be 'Google.Chrome'
        Resolve-WingetListId -ListedId 'Google.Chrome' -ListedSource '' -InstallableIds $null | Should -BeNullOrEmpty
        Resolve-WingetListId -ListedId "Microsoft.VisualStudio.2022.Bui$([char]0x2026)" -ListedSource 'winget' -InstallableIds $null | Should -BeNullOrEmpty
    }
}
