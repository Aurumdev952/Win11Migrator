#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the shared Robocopy wrapper (argument building and output parsing).
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Core/Invoke-Robocopy.ps1"

    $config = @{
        RobocopyThreadsByTarget = [PSCustomObject]@{ Local = 16; Network = 16; USB = 4; Cloud = 8 }
        RobocopyRetries         = 1
        RobocopyWaitSeconds     = 1
        MaxFileSizeMB           = 4096
        RobocopyUnbufferedIO    = $false
    }
    $exclusions = @{ Directories = @('node_modules', '.venv'); Files = @('*.tmp', '~$*') }
}

Describe 'New-RobocopyArgumentList' {
    It 'skips junctions and suppresses per-directory and percentage output' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Config $config
        $a | Should -Contain '/XJ'
        $a | Should -Contain '/NDL'
        $a | Should -Contain '/NP'
        $a | Should -Contain '/BYTES'
        $a | Should -Contain '/E'
        $a | Should -Not -Contain '/MIR'
    }

    It 'uses fast-fail retries from config' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Config $config
        $a | Should -Contain '/R:1'
        $a | Should -Contain '/W:1'
    }

    It 'picks thread count per target kind' -TestCases @(
        @{ Kind = 'USB'; Expected = '/MT:4' }
        @{ Kind = 'Network'; Expected = '/MT:16' }
        @{ Kind = 'Cloud'; Expected = '/MT:8' }
    ) {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -TargetKind $Kind -Config $config
        $a | Should -Contain $Expected
    }

    It 'falls back to built-in thread defaults when config has no map' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'E:\x' -TargetKind USB -Config @{}
        $a | Should -Contain '/MT:4'
    }

    It 'applies the file size cap in bytes' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Config $config
        $a | Should -Contain "/MAX:$(4096 * 1MB)"
    }

    It 'passes every directory exclusion after /XD and every file pattern after /XF' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Exclusions $exclusions -Config $config
        $xd = [array]::IndexOf($a, '/XD')
        $xf = [array]::IndexOf($a, '/XF')
        $xd | Should -BeGreaterThan 1
        $xf | Should -BeGreaterThan 1
        $a[$xd + 1] | Should -Be 'node_modules'
        $a[$xd + 2] | Should -Be '.venv'
        $a[$xf + 1] | Should -Be '*.tmp'
        $a[$xf + 2] | Should -Be '~$*'
    }

    It 'omits /XD and /XF when there is nothing to exclude' {
        $a = New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Exclusions @{ Directories = @(); Files = @() } -Config $config
        $a | Should -Not -Contain '/XD'
        $a | Should -Not -Contain '/XF'
    }

    It 'enables SMB compression only when a side is a UNC path' {
        (New-RobocopyArgumentList -Source 'C:\src' -Destination '\\PC2\W11MIncoming$\pkg' -Config $config) | Should -Contain '/COMPRESS'
        (New-RobocopyArgumentList -Source '\\NAS\share' -Destination 'C:\x' -Config $config) | Should -Contain '/COMPRESS'
        (New-RobocopyArgumentList -Source 'C:\src' -Destination 'D:\dst' -Config $config) | Should -Not -Contain '/COMPRESS'
    }

    It 'mirrors only on request' {
        (New-RobocopyArgumentList -Source 'C:\a' -Destination 'D:\b' -Mirror -Config $config) | Should -Contain '/MIR'
    }

    It 'copies security descriptors only on request' {
        (New-RobocopyArgumentList -Source 'C:\a' -Destination 'D:\b' -CopySecurity -Config $config) | Should -Contain '/COPY:DATS'
        (New-RobocopyArgumentList -Source 'C:\a' -Destination 'D:\b' -Config $config) | Should -Contain '/COPY:DAT'
    }

    It 'lists without copying or logging file names in measure mode' {
        $a = New-RobocopyArgumentList -Source 'C:\a' -Destination 'D:\b' -ListOnly -Config $config
        $a | Should -Contain '/L'
        $a | Should -Contain '/NFL'
    }
}

Describe 'ConvertTo-ProcessArgumentString' {
    It 'keeps a drive root valid inside quotes-free output' {
        ConvertTo-ProcessArgumentString @('C:\') | Should -Be 'C:\.'
    }

    It 'quotes paths with spaces and drops a trailing backslash that would escape the quote' {
        ConvertTo-ProcessArgumentString @('C:\My Docs\', 'D:\x') | Should -Be '"C:\My Docs" D:\x'
    }

    It 'leaves wildcard patterns unquoted' {
        ConvertTo-ProcessArgumentString @('/XF', '~$*', '*.tmp') | Should -Be '/XF ~$* *.tmp'
    }
}

Describe 'Get-RobocopyLineBytes' {
    It 'reads the size of a copied file line' {
        Get-RobocopyLineBytes "`t    New File  `t`t   1048576`tC:\Users\a\Documents\big.iso" | Should -Be 1048576
    }

    It 'reads the size from a localized line' {
        Get-RobocopyLineBytes "`t    Nouveau fichier  `t`t      2048`tC:\Users\a\doc 2024.txt" | Should -Be 2048
    }

    It 'does not count EXTRA entries' {
        Get-RobocopyLineBytes "`t   *EXTRA File  `t`t      4096`told.txt" | Should -Be 0
    }

    It 'ignores error and blank lines' {
        Get-RobocopyLineBytes '2026/10/08 10:00:00 ERROR 5 (0x00000005) Copying File C:\x' | Should -Be 0
        Get-RobocopyLineBytes '' | Should -Be 0
    }
}

Describe 'ConvertFrom-RobocopySummary' {
    It 'parses the English job summary' {
        $lines = @(
            '------------------------------------------------------------------------------',
            '',
            '               Total    Copied   Skipped  Mismatch    FAILED    Extras',
            '    Dirs :         3         2         1         0         0         0',
            '   Files :        10         8         1         0         1         0',
            '   Bytes :    123456    100000     23456         0         0         0',
            '   Times :   0:00:01   0:00:00                       0:00:00   0:00:00',
            '   Ended : Thursday, October 8, 2026 10:00:00 AM'
        )
        $s = ConvertFrom-RobocopySummary $lines
        $s.FilesTotal | Should -Be 10
        $s.FilesCopied | Should -Be 8
        $s.FilesFailed | Should -Be 1
        $s.BytesTotal | Should -Be 123456
        $s.BytesCopied | Should -Be 100000
    }

    It 'parses a French job summary by row position' {
        $lines = @(
            '------------------------------------------------------------------------------',
            '               Total    Copié   Ignoré  Incompatibilité    ÉCHEC    Extras',
            '     Rép :         5         5         0         0         0         0',
            'Fichiers :        42        40         2         0         0         0',
            '  Octets :   9999999   9000000    999999         0         0         0',
            '  Heures :   0:00:03   0:00:02                       0:00:00   0:00:00'
        )
        $s = ConvertFrom-RobocopySummary $lines
        $s.FilesCopied | Should -Be 40
        $s.BytesCopied | Should -Be 9000000
    }

    It 'ignores numeric file names streamed before the summary separator' {
        $lines = @(
            "`t    New File  `t`t      10`tC:\Users\a\1 2 3 4 5 6 scan.pdf",
            '------------------------------------------------------------------------------',
            '    Dirs :         1         1         0         0         0         0',
            '   Files :         1         1         0         0         0         0',
            '   Bytes :        10        10         0         0         0         0'
        )
        (ConvertFrom-RobocopySummary $lines).BytesCopied | Should -Be 10
    }

    It 'returns nothing when the output has no summary' {
        ConvertFrom-RobocopySummary @('ERROR : Invalid Parameter #3') | Should -BeNullOrEmpty
    }
}

Describe 'Format-TransferRate' {
    It 'shows progress, rate and remaining time' {
        $start = [datetime]'2026-10-08T10:00:00Z'
        $now = $start.AddSeconds(100)
        Format-TransferRate -BytesDone (1GB) -BytesTotal (4GB) -StartedUtc $start -NowUtc $now |
            Should -Be ('{0:N1} of {1:N1} GB, {2:N1} MB/s, about 5 min left' -f 1, 4, 10.24)
    }

    It 'stays empty before any bytes move' {
        Format-TransferRate -BytesDone 0 -BytesTotal (4GB) -StartedUtc ([datetime]::UtcNow) | Should -BeNullOrEmpty
    }

    It 'omits the estimate when the total is unknown' {
        $start = [datetime]'2026-10-08T10:00:00Z'
        Format-TransferRate -BytesDone (2GB) -BytesTotal 0 -StartedUtc $start -NowUtc $start.AddSeconds(10) | Should -Not -Match 'left'
    }
}
