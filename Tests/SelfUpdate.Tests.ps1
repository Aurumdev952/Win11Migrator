#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for picking and verifying self-update downloads.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Core/Invoke-SelfUpdate.ps1"
    function New-TempFile { param([string]$Content) $p = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_upd_$([guid]::NewGuid().ToString('N')).msi"; Set-Content -Path $p -Value $Content -NoNewline; $p }
}

Describe 'Select-UpdateAsset' {
    It 'prefers the MSI, which upgrades an installed copy in place' {
        $assets = @(
            [pscustomobject]@{ name = 'Win11Migrator-1.2.0-portable.exe' },
            [pscustomobject]@{ name = 'Win11Migrator-1.2.0-x64.msi' },
            [pscustomobject]@{ name = 'Win11Migrator_Setup_1.2.0.exe' }
        )
        (Select-UpdateAsset $assets).name | Should -Be 'Win11Migrator-1.2.0-x64.msi'
    }

    It 'falls back to the older setup exe' {
        (Select-UpdateAsset @([pscustomobject]@{ name = 'Win11Migrator_Setup_1.0.3.exe' })).name | Should -Be 'Win11Migrator_Setup_1.0.3.exe'
    }

    It 'never picks the portable exe' {
        Select-UpdateAsset @([pscustomobject]@{ name = 'Win11Migrator-1.2.0-portable.exe' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-ExpectedSha256' {
    It 'finds the hash for the named file' {
        $sums = "aaaa$('0' * 60)  Win11Migrator-1.2.0-portable.zip`r`nbbbb$('1' * 60)  Win11Migrator-1.2.0-x64.msi`r`n"
        Get-ExpectedSha256 -SumsText $sums -FileName 'Win11Migrator-1.2.0-x64.msi' | Should -Be ("BBBB$('1' * 60)")
    }

    It 'returns nothing for a file that is not listed' {
        Get-ExpectedSha256 -SumsText "$('a' * 64)  other.zip" -FileName 'Win11Migrator-1.2.0-x64.msi' | Should -BeNullOrEmpty
    }
}

Describe 'Test-UpdateFile without a configured signer' {
    BeforeAll { $update = [pscustomobject]@{ FileName = 'Win11Migrator-1.2.0-x64.msi'; SumsUrl = 'https://example.invalid/SHA256SUMS.txt' } }

    It 'accepts a download that matches the published checksum' {
        $file = New-TempFile 'genuine installer'
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = "$hash  Win11Migrator-1.2.0-x64.msi`n" } }
        { Test-UpdateFile -Path $file -Update $update -SignerSubject '' } | Should -Not -Throw
    }

    It 'rejects a download that was altered' {
        $file = New-TempFile 'tampered installer'
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = "$('0' * 64)  Win11Migrator-1.2.0-x64.msi`n" } }
        { Test-UpdateFile -Path $file -Update $update -SignerSubject '' } | Should -Throw '*checksum*'
    }

    It 'rejects a release without checksums' {
        $file = New-TempFile 'x'
        { Test-UpdateFile -Path $file -Update ([pscustomobject]@{ FileName = 'a.msi'; SumsUrl = $null }) -SignerSubject '' } | Should -Throw '*SHA256SUMS*'
    }
}
