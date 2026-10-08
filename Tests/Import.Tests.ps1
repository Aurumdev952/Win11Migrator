#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for restoring packages: user data paths, move-vs-copy, AppData layouts,
    import status, and the import engine's ordering.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    foreach ($core in 'Initialize-Environment', 'Write-MigrationLog', 'Invoke-Robocopy', 'Get-MigrationExclusions', 'Invoke-MigrationImport') {
        . "$ProjectRoot/Core/$core.ps1"
    }
    foreach ($f in 'Restore-PackageFolder', 'Import-UserProfile', 'Import-AppDataSettings', 'Get-UserProfilePaths') {
        . "$ProjectRoot/Modules/UserData/$f.ps1"
    }
    foreach ($core in 'Get-PackageFingerprint', 'New-RollbackSnapshot', 'Get-OSMigrationContext') { . "$ProjectRoot/Core/$core.ps1" }
    foreach ($report in 'New-CompletionReport', 'New-ManualInstallReport') { . "$ProjectRoot/Reports/$report.ps1" }
    $script:SilentMode = $true

    function New-TempDir {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_imp_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        return $dir
    }
    function Add-File {
        param([string]$Path, [string]$Content = 'x')
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        Set-Content -Path $Path -Value $Content
    }
    function New-DataItem {
        param([string]$Category, [string]$RelativePath = $Category, [string]$ExportStatus = 'Success')
        $i = [UserDataItem]::new()
        $i.Category = $Category
        $i.RelativePath = $RelativePath
        $i.Selected = $true
        $i.ExportStatus = $ExportStatus
        return $i
    }
    function P { param([string[]]$Parts) $acc = $Parts[0]; foreach ($x in $Parts[1..($Parts.Count - 1)]) { $acc = Join-Path $acc $x }; $acc }
}

Describe 'Import-UserProfile' {
    BeforeEach {
        $pkg = New-TempDir
        $userHome = New-TempDir
        $env:USERPROFILE = $userHome
        $targets = @{ Documents = (P $userHome, 'Documents'); Desktop = (P $userHome, 'Desktop') }
        Mock Invoke-Robocopy {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
            [PSCustomObject]@{ ExitCode = 1; Success = $true; Files = 1; Bytes = 1L; Failed = 0; Tail = @() }
        }
    }

    It 'restores a folder exported to UserData\Documents into the target Documents folder' {
        Add-File (P $pkg, 'UserData', 'Documents', 'report.docx')
        $item = New-DataItem 'Documents'
        Import-UserProfile -Items @($item) -PackagePath $pkg -TargetProfilePaths $targets | Out-Null
        Test-Path (P $userHome, 'Documents', 'report.docx') | Should -BeTrue
        $item.ImportStatus | Should -Be 'Success'
        $item.ExportStatus | Should -Be 'Success'
    }

    It 'restores custom folders under the user profile by their package name' {
        Add-File (P $pkg, 'UserData', 'Projects (2)', 'main.py')
        $item = New-DataItem 'Custom' 'Projects (2)'
        Import-UserProfile -Items @($item) -PackagePath $pkg -TargetProfilePaths $targets | Out-Null
        Test-Path (P $userHome, 'Projects (2)', 'main.py') | Should -BeTrue
    }

    It 'skips folders the export skipped and leaves AppData to its own importer' {
        $cloud = New-DataItem 'Desktop' -ExportStatus 'Skipped'
        $appData = New-DataItem 'AppData' (P 'AppData', 'Roaming', 'X')
        Import-UserProfile -Items @($cloud, $appData) -PackagePath $pkg -TargetProfilePaths $targets | Out-Null
        $cloud.ImportStatus | Should -Be 'Skipped'
        $appData.ImportStatus | Should -BeNullOrEmpty
        Should -Invoke Invoke-Robocopy -Times 0
    }

    It 'marks a folder missing from the package as failed' {
        $item = New-DataItem 'Documents'
        Import-UserProfile -Items @($item) -PackagePath $pkg -TargetProfilePaths $targets | Out-Null
        $item.ImportStatus | Should -Be 'Failed'
    }

    It 'moves files into place without copying when asked to consume the package' {
        Add-File (P $pkg, 'UserData', 'Documents', 'a', 'deep.txt')
        Add-File (P $pkg, 'UserData', 'Documents', 'top.txt')
        $item = New-DataItem 'Documents'
        Import-UserProfile -Items @($item) -PackagePath $pkg -TargetProfilePaths $targets -MoveFromPackage | Out-Null
        Test-Path (P $userHome, 'Documents', 'a', 'deep.txt') | Should -BeTrue
        Test-Path (P $pkg, 'UserData', 'Documents', 'a', 'deep.txt') | Should -BeFalse
        Should -Invoke Invoke-Robocopy -Times 0
        $item.ImportStatus | Should -Be 'Success'
    }

    It 'merges into folders that already exist and hands real conflicts to robocopy' {
        Add-File (P $userHome, 'Documents', 'shared', 'old.txt')
        Add-File (P $userHome, 'Documents', 'same.txt') 'target version'
        Add-File (P $pkg, 'UserData', 'Documents', 'shared', 'new.txt')
        Add-File (P $pkg, 'UserData', 'Documents', 'same.txt') 'package version'
        Import-UserProfile -Items @(New-DataItem 'Documents') -PackagePath $pkg -TargetProfilePaths $targets -MoveFromPackage | Out-Null
        Test-Path (P $userHome, 'Documents', 'shared', 'old.txt') | Should -BeTrue
        Test-Path (P $userHome, 'Documents', 'shared', 'new.txt') | Should -BeTrue
        Should -Invoke Invoke-Robocopy -Times 1
    }
}

Describe 'Import-AppDataSettings' {
    BeforeEach {
        $pkg = New-TempDir
        $env:APPDATA = New-TempDir
        $env:LOCALAPPDATA = New-TempDir
        Mock Invoke-Robocopy {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
            [PSCustomObject]@{ ExitCode = 1; Success = $true; Files = 1; Bytes = 1L; Failed = 0; Tail = @() }
        }
    }

    It 'restores the current layout into Roaming' {
        $rel = P 'AppData', 'Roaming', 'Sticky'
        Add-File (P $pkg, $rel, 'notes.db')
        $item = New-DataItem 'AppData' $rel
        Import-AppDataSettings -Items @($item) -PackagePath $pkg | Out-Null
        Test-Path (P $env:APPDATA, 'Sticky', 'notes.db') | Should -BeTrue
        $item.ImportStatus | Should -Be 'Success'
    }

    It 'still restores packages from 1.0.x, which nested AppData one level deeper' {
        $rel = P 'AppData', 'Local', 'Themes'
        Add-File (P $pkg, 'AppData', $rel, 'theme.ini')
        Import-AppDataSettings -Items @(New-DataItem 'AppData' $rel) -PackagePath $pkg | Out-Null
        Test-Path (P $env:LOCALAPPDATA, 'Themes', 'theme.ini') | Should -BeTrue
    }
}

Describe 'Get-ImportWorkPath' {
    It 'uses the package when it is writable' {
        $pkg = New-TempDir
        Get-ImportWorkPath -PackagePath $pkg -LocalRoot (New-TempDir) | Should -Be $pkg
    }

    It 'falls back to a local folder when the package is read-only' -Skip:($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or (id -u) -eq '0') {
        $pkg = New-TempDir
        chmod 555 $pkg
        try {
            $local = New-TempDir
            Get-ImportWorkPath -PackagePath $pkg -LocalRoot $local | Should -BeLike "$local*"
        } finally {
            chmod 755 $pkg
        }
    }
}

Describe 'Invoke-MigrationImport' {
    BeforeEach {
        $pkg = New-TempDir
        $userHome = New-TempDir
        $env:USERPROFILE = $userHome
        $script:Config = @{ PackagePath = (New-TempDir) }
        Add-File (P $pkg, 'UserData', 'Documents', 'a.txt')

        $manual = [MigrationApp]::new(); $manual.Name = 'Legacy Tool'; $manual.InstallMethod = 'Manual'; $manual.Selected = $true
        $chrome = [MigrationApp]::new(); $chrome.Name = 'Chrome'; $chrome.InstallMethod = 'Winget'; $chrome.Selected = $true
        $manifest = [MigrationManifest]::new()
        $manifest.Apps = @($manual, $chrome)
        $manifest.UserData = @(New-DataItem 'Documents')

        $script:fileRestoredBeforeWait = $null
        Mock Get-UserProfilePaths { @{ Documents = (P $userHome, 'Documents') } }
        Mock New-RollbackSnapshot { @{ Success = $true } }
        Mock Get-OSMigrationContext { @{ IsWindows11 = $true } }
        Mock Start-AppInstallWorker { @{ Fake = $true } }
        Mock Wait-AppInstallWorker {
            if ($null -eq $script:fileRestoredBeforeWait) { $script:fileRestoredBeforeWait = Test-Path (P $userHome, 'Documents', 'a.txt') }
            $done = [MigrationApp]::new(); $done.Name = 'Chrome'; $done.InstallStatus = 'Success'
            @($done)
        }
        Mock New-CompletionReport { 'report.html' }
        Mock New-ManualInstallReport { 'manual.html' }
        Mock Invoke-Robocopy {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
            [PSCustomObject]@{ ExitCode = 1; Success = $true; Files = 1; Bytes = 1L; Failed = 0; Tail = @() }
        }
    }

    It 'restores files while apps install, before waiting for the installer' {
        Invoke-MigrationImport -PackagePath $pkg -Manifest $manifest | Out-Null
        $script:fileRestoredBeforeWait | Should -BeTrue
    }

    It 'keeps manual apps in the manifest and records install results on the rest' {
        Invoke-MigrationImport -PackagePath $pkg -Manifest $manifest | Out-Null
        @($manifest.Apps).Count | Should -Be 2
        ($manifest.Apps | Where-Object Name -eq 'Chrome').InstallStatus | Should -Be 'Success'
        Should -Invoke New-ManualInstallReport -Times 1 -ParameterFilter { @($Apps).Name -contains 'Legacy Tool' }
    }

    It 'uses an install worker that was started earlier instead of starting another' {
        Invoke-MigrationImport -PackagePath $pkg -Manifest $manifest -AppWorker @{ Early = $true } | Out-Null
        Should -Invoke Start-AppInstallWorker -Times 0
    }

    It 'counts restored folders and installed apps' {
        $r = Invoke-MigrationImport -PackagePath $pkg -Manifest $manifest
        $r.Succeeded | Should -Be 2
        $r.Failed | Should -Be 0
    }
}
