#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the shared export engine and destination resolution.
    Robocopy is replaced by a Copy-Item stand-in so the tests run on any OS.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    foreach ($core in 'Initialize-Environment', 'Write-MigrationLog', 'ConvertTo-MigrationManifest', 'Invoke-Robocopy',
                      'Get-MigrationExclusions', 'Invoke-MigrationExport') {
        . "$ProjectRoot/Core/$core.ps1"
    }
    . "$ProjectRoot/Modules/UserData/Export-UserProfile.ps1"
    . "$ProjectRoot/Modules/UserData/Export-AppDataSettings.ps1"
    . "$ProjectRoot/Modules/StorageTargets/Resolve-ExportDestination.ps1"
    . "$ProjectRoot/Modules/StorageTargets/Copy-MigratorToTarget.ps1"
    $script:SilentMode = $true

    function New-TempDir {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_test_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        return $dir
    }

    function New-UserFolder {
        param([string]$Root, [string]$Name, [string[]]$Files)
        $folder = Join-Path $Root $Name
        foreach ($f in $Files) {
            $path = Join-Path $folder $f
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            Set-Content -Path $path -Value "content of $f"
        }
        return $folder
    }

    function New-Item-Data {
        param([string]$Path, [string]$Name, [switch]$Cloud)
        $item = [UserDataItem]::new()
        $item.SourcePath = $Path
        $item.RelativePath = $Name
        $item.Category = $Name
        $item.Selected = $true
        if ($Cloud) { $item.IsCloudSynced = $true; $item.SkipCloudSync = $true; $item.CloudProvider = 'OneDrive' }
        return $item
    }
}

Describe 'Resolve-ExportDestination' {
    BeforeAll {
        $script:Config = @{ PackagePath = '/tmp/local-pkgs'; DiskSpaceBufferMB = 500 }
        Mock Get-PathFreeSpace { 100GB }
    }

    It 'places USB packages next to the bundled tool on the drive root' {
        $d = Resolve-ExportDestination -StorageTarget @{ Type = 'USB'; Path = 'E:\' }
        $d.Root | Should -Be ([System.IO.Path]::Combine('E:\', 'Win11Migrator'))
        $d.TargetKind | Should -Be 'USB'
        $d.CopyMigrator | Should -BeTrue
    }

    It 'keeps a custom folder path intact instead of treating it as a drive letter' {
        $d = Resolve-ExportDestination -StorageTarget @{ Type = 'Custom'; Path = 'D:\Backups' }
        $d.Root | Should -Be ([System.IO.Path]::Combine('D:\Backups', 'Win11Migrator'))
        $d.Root | Should -Not -Match 'Backups:'
    }

    It 'writes a LAN receive package straight into the receiver share without bundling the tool' {
        $d = Resolve-ExportDestination -StorageTarget @{ Type = 'LanReceive'; Path = '\\PC2\W11MIncoming$' }
        $d.Root | Should -Be '\\PC2\W11MIncoming$'
        $d.TargetKind | Should -Be 'Network'
        $d.CopyMigrator | Should -BeFalse
    }

    It 'uses the local package folder when no target is chosen' {
        (Resolve-ExportDestination -StorageTarget $null).Root | Should -Be '/tmp/local-pkgs'
    }

    It 'refuses to start when the destination cannot hold the data plus buffer' {
        Mock Get-PathFreeSpace { 10GB }
        { Resolve-ExportDestination -StorageTarget @{ Type = 'USB'; Path = 'E:' } -RequiredBytes (12GB) } |
            Should -Throw '*Not enough space*'
    }

    It 'proceeds when free space is unknown' {
        Mock Get-PathFreeSpace { $null }
        { Resolve-ExportDestination -StorageTarget @{ Type = 'NetworkShare'; Path = '\\nas\x' } -RequiredBytes (1TB) } | Should -Not -Throw
    }

    It 'rejects unknown target types' {
        { Resolve-ExportDestination -StorageTarget @{ Type = 'Floppy'; Path = 'A:' } } | Should -Throw '*Unknown storage target*'
    }
}

Describe 'Invoke-MigrationExport' {
    BeforeEach {
        $script:Config = @{ PackagePath = (New-TempDir); AppDataInclude = @() }
        $source = New-TempDir
        $pkg = Join-Path (New-TempDir) 'Win11Migration_TEST_20261008_100000'
        $script:robocopyCalls = [System.Collections.ArrayList]::new()
        $script:manifestSeenBeforeCopy = $null

        Mock Invoke-Robocopy {
            $script:manifestSeenBeforeCopy = Test-Path (Join-Path $pkg 'manifest.json')
            $null = $script:robocopyCalls.Add(@{ Source = $Source; Destination = $Destination; Exclusions = $Exclusions; TargetKind = $TargetKind })
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
            $bytes = (Get-ChildItem $Source -Recurse -File | Measure-Object Length -Sum).Sum
            if ($Progress) { $Progress['BytesDone'] = [long]$Progress['BytesDone'] + $bytes }
            [PSCustomObject]@{ ExitCode = 1; Success = $true; Files = 1; Bytes = [long]$bytes; Failed = 0; Tail = @() }
        }
    }

    It 'writes the manifest before copying user data so a receiver can start installing apps' {
        $docs = New-UserFolder $source 'Documents' @('a.txt')
        $selection = @{ UserData = @(New-Item-Data $docs 'Documents'); SettingsFlags = @{}; IncludeAppData = $false }
        Invoke-MigrationExport -PackagePath $pkg -Selection $selection | Out-Null
        $script:manifestSeenBeforeCopy | Should -BeTrue
        (Get-Content (Join-Path $pkg 'manifest.json') -Raw | ConvertFrom-Json).Metadata.ExportComplete | Should -BeTrue
    }

    It 'copies each folder under UserData by its relative path and passes the exclusions to robocopy' {
        $docs = New-UserFolder $source 'Documents' @('report.docx')
        $ex = @{ Directories = @('node_modules'); Files = @('*.tmp') }
        $selection = @{ UserData = @(New-Item-Data $docs 'Documents'); SettingsFlags = @{}; IncludeAppData = $false; Exclusions = $ex }
        $result = Invoke-MigrationExport -PackagePath $pkg -Selection $selection -TargetKind Network
        Test-Path (Join-Path (Join-Path (Join-Path $pkg 'UserData') 'Documents') 'report.docx') | Should -BeTrue
        $script:robocopyCalls[0].Exclusions.Directories | Should -Contain 'node_modules'
        $script:robocopyCalls[0].TargetKind | Should -Be 'Network'
        $result.UserData[0].ExportStatus | Should -Be 'Success'
    }

    It 'leaves cloud-synced folders to the sync client' {
        $docs = New-UserFolder $source 'Documents' @('a.txt')
        $selection = @{ UserData = @(New-Item-Data $docs 'Documents' -Cloud); SettingsFlags = @{}; IncludeAppData = $false }
        $result = Invoke-MigrationExport -PackagePath $pkg -Selection $selection
        $script:robocopyCalls.Count | Should -Be 0
        $result.UserData[0].ExportStatus | Should -Be 'Skipped'
    }

    It 'gives custom folders with the same name separate package folders' {
        $a = New-UserFolder (Join-Path $source 'one') 'Projects' @('a.txt')
        $b = New-UserFolder (Join-Path $source 'two') 'Projects' @('b.txt')
        $items = @(
            @{ Name = 'Projects'; SourcePath = $a; Selected = $true; IsCustom = $true },
            @{ Name = 'Projects'; SourcePath = $b; Selected = $true; IsCustom = $true }
        )
        $result = Invoke-MigrationExport -PackagePath $pkg -Selection @{ UserData = $items; SettingsFlags = @{}; IncludeAppData = $false }
        @($result.UserData.RelativePath) | Should -Be @('Projects', 'Projects (2)')
        Test-Path (Join-Path (Join-Path (Join-Path $pkg 'UserData') 'Projects (2)') 'b.txt') | Should -BeTrue
    }

    It 'skips unselected folders' {
        $docs = New-UserFolder $source 'Documents' @('a.txt')
        $item = New-Item-Data $docs 'Documents'
        $item.Selected = $false
        Invoke-MigrationExport -PackagePath $pkg -Selection @{ UserData = @($item); SettingsFlags = @{}; IncludeAppData = $false } | Out-Null
        $script:robocopyCalls.Count | Should -Be 0
    }

    It 'lays AppData out as AppData, then Roaming or Local, then the folder, at the package root' {
        $roaming = New-TempDir
        New-UserFolder $roaming 'Sticky' @('notes.db') | Out-Null
        $env:APPDATA = $roaming
        $env:LOCALAPPDATA = Join-Path $roaming 'none'
        $script:Config['AppDataInclude'] = @('Sticky')
        $result = Invoke-MigrationExport -PackagePath $pkg -Selection @{ UserData = @(); SettingsFlags = @{}; IncludeAppData = $true }
        $appItem = $result.UserData | Where-Object { $_.Category -eq 'AppData' }
        $appItem.RelativePath | Should -Be (Join-Path (Join-Path 'AppData' 'Roaming') 'Sticky')
        Test-Path (Join-Path (Join-Path $pkg $appItem.RelativePath) 'notes.db') | Should -BeTrue
    }
}

Describe 'Invoke-MigrationExportToDestination' {
    BeforeEach {
        $root = New-TempDir
        $script:Config = @{ PackagePath = (New-TempDir); AppDataInclude = @() }
        Mock Invoke-Robocopy { [PSCustomObject]@{ ExitCode = 0; Success = $true; Files = 0; Bytes = 0L; Failed = 0; Tail = @() } }
        Mock Copy-MigratorToTarget { [PSCustomObject]@{ Copied = $true } }
        $destination = [PSCustomObject]@{ Type = 'USB'; Root = $root; TargetKind = 'USB'; CopyMigrator = $true; FreeBytes = 1TB }
        $selection = @{ UserData = @(); SettingsFlags = @{}; IncludeAppData = $false }
    }

    It 'marks the transfer complete and bundles the tool' {
        $r = Invoke-MigrationExportToDestination -Destination $destination -Selection $selection
        (Read-TransferStatus -PackagePath $r.PackagePath).State | Should -Be 'Complete'
        Should -Invoke Copy-MigratorToTarget -Times 1 -ParameterFilter { $TargetBasePath -eq $root }
    }

    It 'resumes into the unfinished package from this computer' {
        $unfinished = Join-Path $root "Win11Migration_$($env:COMPUTERNAME)_20260101_000000"
        New-Item -ItemType Directory -Path $unfinished | Out-Null
        Write-TransferStatus -PackagePath $unfinished -State InProgress
        $r = Invoke-MigrationExportToDestination -Destination $destination -Selection $selection -Resume
        $r.PackagePath | Should -Be $unfinished
    }

    It 'starts a new package when the previous one finished' {
        $done = Join-Path $root "Win11Migration_$($env:COMPUTERNAME)_20260101_000000"
        New-Item -ItemType Directory -Path $done | Out-Null
        Write-TransferStatus -PackagePath $done -State Complete
        $r = Invoke-MigrationExportToDestination -Destination $destination -Selection $selection -Resume
        $r.PackagePath | Should -Not -Be $done
    }
}
