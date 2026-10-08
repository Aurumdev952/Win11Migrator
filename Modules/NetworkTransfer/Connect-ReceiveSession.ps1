<#
========================================================================================================
    Title:          Win11Migrator - LAN Receive Connector (source PC)
    Filename:       Connect-ReceiveSession.ps1
    Description:    Finds PCs waiting in Receive mode and connects to one with its pairing code, so the
                    export can write the package straight into the receiving PC's share.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Get-BroadcastAddresses {
    # Directed broadcasts reach every subnet this PC is on; 255.255.255.255 alone often leaves by one NIC only.
    $addresses = [System.Collections.Generic.List[string]]::new()
    $addresses.Add('255.255.255.255')
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
                if ($u.Address.AddressFamily -ne 'InterNetwork' -or -not $u.IPv4Mask) { continue }
                $ip = $u.Address.GetAddressBytes()
                $mask = $u.IPv4Mask.GetAddressBytes()
                $bcast = for ($i = 0; $i -lt 4; $i++) { $ip[$i] -bor (255 -bxor $mask[$i]) }
                $text = $bcast -join '.'
                if (-not $addresses.Contains($text)) { $addresses.Add($text) }
            }
        }
    } catch { }
    return $addresses.ToArray()
}

function Find-Receivers {
    <#
    .SYNOPSIS
        Lists PCs on the local network that are waiting in Receive mode.
    .PARAMETER Address
        Ask specific hosts (name or IP) instead of broadcasting.
    .OUTPUTS
        PSCustomObject per receiver: Computer, Address, Addresses, Version, FreeBytes.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Address,
        [int]$TimeoutMs = 2000,
        [int]$Port = $script:ReceiveProtocol.DiscoveryPort
    )

    $client = [System.Net.Sockets.UdpClient]::new(0)
    try {
        $client.EnableBroadcast = $true
        $message = [System.Text.Encoding]::UTF8.GetBytes($script:ReceiveProtocol.DiscoverMessage)
        $targets = if ($Address) { $Address } else { Get-BroadcastAddresses }
        foreach ($target in $targets) {
            try {
                $ip = [System.Net.Dns]::GetHostAddresses($target) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                if ($ip) { $null = $client.Send($message, $message.Length, [System.Net.IPEndPoint]::new($ip, $Port)) }
            } catch {
                Write-MigrationLog -Message "Discovery could not reach $($target): $($_.Exception.Message)" -Level Debug
            }
        }

        $found = @{}
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { break }
            $client.Client.ReceiveTimeout = [Math]::Max(1, $remaining)
            $from = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try { $data = $client.Receive([ref]$from) } catch [System.Net.Sockets.SocketException] { break }
            $receiver = ConvertFrom-DiscoveryReply -Text ([System.Text.Encoding]::UTF8.GetString($data)) -FromAddress $from.Address.ToString()
            if ($receiver -and -not $found.ContainsKey($receiver.Computer)) { $found[$receiver.Computer] = $receiver }
        }
        return @($found.Values | Sort-Object Computer)
    } finally {
        $client.Dispose()
    }
}

function Connect-ReceiveSession {
    <#
    .SYNOPSIS
        Authenticates to a receiving PC with its pairing code and returns the storage target for export.
    .PARAMETER Computer
        The receiver's name or IP address, as listed by Find-Receivers or typed by the user.
    .OUTPUTS
        Hashtable @{ Type = 'LanReceive'; Path = '\\<address>\W11MIncoming$'; Computer; FreeBytes }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Computer,
        [Parameter(Mandatory)][string]$PairingCode
    )

    $code = ConvertTo-PairingCode $PairingCode
    $receiver = @(Find-Receivers -Address $Computer -TimeoutMs 2500) | Select-Object -First 1
    if (-not $receiver) {
        throw "$Computer did not answer. On that PC, choose 'Receive from another PC' and keep the window open. Both PCs must be on the same network."
    }

    $share = Get-ReceiveSharePath -Address $receiver.Address
    $user = "$($receiver.Computer)\$($script:ReceiveProtocol.AccountName)"
    $password = ConvertTo-ReceivePassword $code

    $null = Invoke-NetUse @($share, '/delete', '/y')
    $mapped = Invoke-NetUse @($share, $password, "/user:$user", '/persistent:no')
    if ($mapped.ExitCode -ne 0) {
        throw "The pairing code was not accepted by $($receiver.Computer). Check the code on its screen. ($($mapped.Output))"
    }

    $probe = Join-Path $share ".connect-test-$([guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
    } catch {
        throw "Connected to $($receiver.Computer) but cannot write to its incoming folder: $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "Connected to receiver $($receiver.Computer) at $share" -Level Success
    return @{
        Type      = 'LanReceive'
        Path      = $share
        Computer  = $receiver.Computer
        FreeBytes = $receiver.FreeBytes
    }
}

function Disconnect-ReceiveSession {
    param([Parameter(Mandatory)][string]$SharePath)
    $null = Invoke-NetUse @($SharePath, '/delete', '/y')
}
