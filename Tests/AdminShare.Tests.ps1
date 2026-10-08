#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the admin-share push: the logon restore command and the connection test.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Core/Write-MigrationLog.ps1"
    . "$ProjectRoot/Modules/NetworkTransfer/Test-RemoteAccess.ps1"
    . "$ProjectRoot/Modules/NetworkTransfer/Register-RemoteRestoreTask.ps1"
    $script:SilentMode = $true
    if (-not (Get-Command Test-WSMan -ErrorAction SilentlyContinue)) { function Test-WSMan { param($ComputerName) } }
}

Describe 'New-RestoreTaskCommand' {
    BeforeAll {
        $cmd = New-RestoreTaskCommand -LocalPackagePath 'C:\Win11Migrator\Win11Migration_PC1_20261008_100000' -LocalMigratorPath 'C:\Win11Migrator'
    }

    It 'imports the delivered package by moving it into the profile' {
        $cmd | Should -Match "-CLI import -PackagePath 'C:\\Win11Migrator\\Win11Migration_PC1_20261008_100000' -MoveFromPackage"
    }

    It 'runs only once, guarded by a flag file written before the import starts' {
        $cmd | Should -Match "if \(-not \(Test-Path '.*restore-started\.flag'\)\)"
        $cmd.IndexOf('New-Item') | Should -BeLessThan $cmd.IndexOf('-CLI import')
    }

    It 'parses as PowerShell' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Test-RemoteAccess' {
    It 'still checks the admin share when ping is blocked' {
        Mock Test-Connection { $false }
        Mock Test-WSMan { throw 'WinRM off' }
        Mock New-PSDrive { [PSCustomObject]@{ Name = 'x' } }
        Mock Remove-PSDrive { }
        Mock New-PSSessionOption { }
        Mock New-PSSession { throw 'no session' }
        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        $r = Test-RemoteAccess -ComputerName 'PC2' -Credential $cred
        $r.Reachable | Should -BeFalse
        $r.AdminShareAvailable | Should -BeTrue
    }
}
