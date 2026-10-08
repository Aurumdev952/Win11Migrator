#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for LAN Receive mode: pairing codes, the derived password, incoming package
    state, and UDP discovery over the loopback interface.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Core/Write-MigrationLog.ps1"
    . "$ProjectRoot/Core/Invoke-MigrationExport.ps1"
    foreach ($f in 'ReceiveProtocol', 'Start-ReceiveSession', 'Connect-ReceiveSession') {
        . "$ProjectRoot/Modules/NetworkTransfer/$f.ps1"
    }
    $script:SilentMode = $true
    if (-not $env:COMPUTERNAME) { $env:COMPUTERNAME = "TESTPC" }

    function New-TempDir {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_rcv_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        return $dir
    }
    function Get-FreeUdpPort {
        $probe = [System.Net.Sockets.UdpClient]::new(0)
        try { return ([System.Net.IPEndPoint]$probe.Client.LocalEndPoint).Port } finally { $probe.Dispose() }
    }
}

Describe 'Pairing codes' {
    It 'are two groups of four characters from the unambiguous alphabet' {
        $code = New-PairingCode
        $code | Should -MatchExactly '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}$'
    }

    It 'differ between sessions' {
        $codes = 1..20 | ForEach-Object { New-PairingCode }
        @($codes | Sort-Object -Unique).Count | Should -Be 20
    }

    It 'accept what a person types: lower case, spaces, no dash' {
        ConvertTo-PairingCode 'abcd 2345' | Should -BeExactly 'ABCD-2345'
        ConvertTo-PairingCode ' ABCD2345 ' | Should -BeExactly 'ABCD-2345'
    }

    It 'reject characters that never appear in a code, naming the culprit' {
        { ConvertTo-PairingCode 'ABC0-2345' } | Should -Throw "*'0'*"
    }

    It 'reject the wrong length' {
        { ConvertTo-PairingCode 'ABCD-234' } | Should -Throw '*8 letters*'
    }
}

Describe 'ConvertTo-ReceivePassword' {
    It 'derives the same password from any typed form of the code' {
        ConvertTo-ReceivePassword 'abcd-2345' | Should -BeExactly (ConvertTo-ReceivePassword 'ABCD2345')
    }

    It 'meets Windows complexity and a 14-character minimum' {
        $p = ConvertTo-ReceivePassword (New-PairingCode)
        $p.Length | Should -BeGreaterOrEqual 14
        $p | Should -MatchExactly '[A-Z]'
        $p | Should -MatchExactly '[a-z]'
        $p | Should -Match '\d'
        $p | Should -Match '[^A-Za-z0-9]'
    }

    It 'differs for different codes' {
        ConvertTo-ReceivePassword 'AAAA-2222' | Should -Not -Be (ConvertTo-ReceivePassword 'AAAA-2223')
    }
}

Describe 'Discovery replies' {
    It 'round-trip the receiver details and prefer the address the reply came from' {
        $text = ConvertTo-DiscoveryReply -Session @{ Computer = 'PC2'; Addresses = @('10.0.0.5'); Version = '1.0.3'; FreeBytes = 5GB }
        $r = ConvertFrom-DiscoveryReply -Text $text -FromAddress '192.168.1.20'
        $r.Computer | Should -Be 'PC2'
        $r.Address | Should -Be '192.168.1.20'
        $r.FreeBytes | Should -Be (5GB)
    }

    It 'ignore traffic that is not from Win11Migrator' {
        ConvertFrom-DiscoveryReply -Text '{"Product":"Other","Computer":"X"}' | Should -BeNullOrEmpty
        ConvertFrom-DiscoveryReply -Text 'not json' | Should -BeNullOrEmpty
    }
}

Describe 'Get-IncomingPackageState' {
    BeforeEach { $incoming = New-TempDir }

    It 'waits until a package folder appears' {
        (Get-IncomingPackageState -IncomingPath $incoming).State | Should -Be 'Waiting'
    }

    It 'reports receiving, then a ready manifest, then completion' {
        $pkg = Join-Path $incoming 'Win11Migration_PC1_20261008_100000'
        New-Item -ItemType Directory -Path $pkg | Out-Null
        (Get-IncomingPackageState -IncomingPath $incoming).State | Should -Be 'Receiving'

        Set-Content (Join-Path $pkg 'manifest.json') '{}'
        Write-TransferStatus -PackagePath $pkg -State InProgress -Phase 'Exporting user data' -BytesTotal 100 -BytesDone 40
        $s = Get-IncomingPackageState -IncomingPath $incoming
        $s.ManifestReady | Should -BeTrue
        $s.BytesDone | Should -Be 40
        $s.SourceComputer | Should -Be $env:COMPUTERNAME

        Write-TransferStatus -PackagePath $pkg -State Complete
        (Get-IncomingPackageState -IncomingPath $incoming).State | Should -Be 'Complete'
    }

    It 'surfaces a failed transfer with its errors' {
        $pkg = Join-Path $incoming 'Win11Migration_PC1_20261008_100000'
        New-Item -ItemType Directory -Path $pkg | Out-Null
        Write-TransferStatus -PackagePath $pkg -State Failed -Errors @('disk full')
        $s = Get-IncomingPackageState -IncomingPath $incoming
        $s.State | Should -Be 'Failed'
        $s.Errors | Should -Contain 'disk full'
    }
}

Describe 'UDP discovery' {
    BeforeAll {
        $port = Get-FreeUdpPort
        $session = @{ Computer = 'RECEIVER-PC'; Addresses = @('127.0.0.1'); Version = '1.0.3'; FreeBytes = 1TB }
        $responder = Start-DiscoveryResponder -Session $session -Port $port
        Start-Sleep -Milliseconds 300
    }
    AfterAll { Stop-DiscoveryResponder -Responder $responder }

    It 'finds a waiting receiver' {
        $found = @(Find-Receivers -Address '127.0.0.1' -Port $port -TimeoutMs 1500)
        $found.Count | Should -Be 1
        $found[0].Computer | Should -Be 'RECEIVER-PC'
        $found[0].Address | Should -Be '127.0.0.1'
        $responder.Control.Error | Should -BeNullOrEmpty
    }

    It 'finds nothing on a port where no receiver listens' {
        @(Find-Receivers -Address '127.0.0.1' -Port (Get-FreeUdpPort) -TimeoutMs 500).Count | Should -Be 0
    }

    It 'releases the port when stopped' {
        $p2 = Get-FreeUdpPort
        $r2 = Start-DiscoveryResponder -Session $session -Port $p2
        Start-Sleep -Milliseconds 200
        Stop-DiscoveryResponder -Responder $r2
        $rebind = [System.Net.Sockets.UdpClient]::new($p2)
        $rebind.Dispose()
    }
}

Describe 'LAN transfer end to end (share replaced by a local folder)' {
    BeforeAll {
        foreach ($core in 'Initialize-Environment', 'ConvertTo-MigrationManifest', 'Read-MigrationManifest', 'Invoke-Robocopy',
                          'Get-MigrationExclusions', 'Invoke-MigrationImport', 'Get-PackageFingerprint', 'New-RollbackSnapshot', 'Get-OSMigrationContext') {
            . "$ProjectRoot/Core/$core.ps1"
        }
        foreach ($f in 'Export-UserProfile', 'Export-AppDataSettings', 'Restore-PackageFolder', 'Import-UserProfile', 'Import-AppDataSettings', 'Get-UserProfilePaths') {
            . "$ProjectRoot/Modules/UserData/$f.ps1"
        }
        foreach ($report in 'New-CompletionReport', 'New-ManualInstallReport') { . "$ProjectRoot/Reports/$report.ps1" }
        . "$ProjectRoot/Modules/StorageTargets/Copy-MigratorToTarget.ps1"
    }

    It 'sends a profile, sees it complete on the receiver, and restores it by moving the files' {
        $script:Config = @{ PackagePath = (New-TempDir); AppDataInclude = @() }
        $source = New-TempDir
        $incoming = New-TempDir
        $userHome = New-TempDir
        $docs = Join-Path $source 'Documents'
        New-Item -ItemType Directory -Path (Join-Path $docs 'proj') -Force | Out-Null
        Set-Content (Join-Path (Join-Path $docs 'proj') 'notes.txt') 'hello'
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $docs 'proj') 'node_modules') -Force | Out-Null

        Mock Invoke-Robocopy {
            # Stand-in for robocopy /XD: copy everything except excluded folder names
            Get-ChildItem -Path $Source -Recurse -File | Where-Object {
                $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
                -not (Test-PathExcluded -RelativePath $rel -Exclusions $(if ($Exclusions) { $Exclusions } else { @{ Directories = @(); Files = @() } }))
            } | ForEach-Object {
                $dest = Join-Path $Destination $_.FullName.Substring($Source.Length).TrimStart('\', '/')
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                Copy-Item $_.FullName $dest
            }
            [PSCustomObject]@{ ExitCode = 1; Success = $true; Files = 1; Bytes = 5L; Failed = 0; Tail = @() }
        }
        Mock Get-UserProfilePaths { @{ Documents = (Join-Path $userHome 'Documents') } }
        Mock New-RollbackSnapshot { @{ Success = $true } }
        Mock Get-OSMigrationContext { @{ IsWindows11 = $true } }
        Mock Start-AppInstallWorker { @{ Fake = $true } }
        Mock Wait-AppInstallWorker { @() }
        Mock New-CompletionReport { 'report.html' }
        Mock Copy-MigratorToTarget { }

        $item = [UserDataItem]::new()
        $item.SourcePath = $docs; $item.RelativePath = 'Documents'; $item.Category = 'Documents'; $item.Selected = $true
        $selection = @{ UserData = @($item); SettingsFlags = @{}; IncludeAppData = $false
                        Exclusions = @{ Directories = @('node_modules'); Files = @() } }
        $destination = [PSCustomObject]@{ Type = 'LanReceive'; Root = $incoming; TargetKind = 'Network'; CopyMigrator = $false; FreeBytes = 1TB }

        (Get-IncomingPackageState -IncomingPath $incoming).State | Should -Be 'Waiting'
        Invoke-MigrationExportToDestination -Destination $destination -Selection $selection | Out-Null

        $arrived = Get-IncomingPackageState -IncomingPath $incoming
        $arrived.State | Should -Be 'Complete'
        $manifest = Read-MigrationManifest -ManifestPath (Join-Path $arrived.PackagePath 'manifest.json')
        $result = Invoke-MigrationImport -PackagePath $arrived.PackagePath -Manifest $manifest -MoveFromPackage

        Test-Path (Join-Path (Join-Path (Join-Path $userHome 'Documents') 'proj') 'notes.txt') | Should -BeTrue
        Test-Path (Join-Path (Join-Path (Join-Path $userHome 'Documents') 'proj') 'node_modules') | Should -BeFalse
        $result.Succeeded | Should -Be 1
        Should -Invoke Copy-MigratorToTarget -Times 0
    }
}
