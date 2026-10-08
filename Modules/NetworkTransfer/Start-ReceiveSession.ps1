<#
========================================================================================================
    Title:          Win11Migrator - LAN Receive Session (target PC)
    Filename:       Start-ReceiveSession.ps1
    Description:    Opens this PC to receive a migration package from another PC on the same network:
                    a temporary account, a hidden share, firewall openings and a discovery responder.
                    Works on workgroup and domain PCs; needs no WinRM and no access to C$.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:ReceiveRegistryKey = 'HKLM:\SOFTWARE\AuthorityGate\Win11Migrator\ReceiveSession'
$script:ReceiveFirewallRules = @('Win11Migrator-Receive-SMB', 'Win11Migrator-Receive-Discovery')

function Get-LocalIPv4Addresses {
    try {
        return @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') } |
            ForEach-Object { $_.Address.ToString() } | Select-Object -Unique)
    } catch {
        return @()
    }
}

function Start-DiscoveryResponder {
    <#
    .SYNOPSIS
        Answers discovery broadcasts from sending PCs in a background runspace until Stop is set.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [int]$Port = $script:ReceiveProtocol.DiscoveryPort
    )

    $control = [hashtable]::Synchronized(@{ Stop = $false; Error = $null })
    $reply = ConvertTo-DiscoveryReply -Session $Session
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript({
        param($Port, $Message, $Reply, $Control)
        $client = $null
        try {
            $client = [System.Net.Sockets.UdpClient]::new()
            $client.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $client.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $Port))
            $client.Client.ReceiveTimeout = 500
            $replyBytes = [System.Text.Encoding]::UTF8.GetBytes($Reply)
            while (-not $Control.Stop) {
                $from = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                try {
                    $data = $client.Receive([ref]$from)
                } catch [System.Net.Sockets.SocketException] {
                    continue
                }
                if ([System.Text.Encoding]::UTF8.GetString($data) -eq $Message) {
                    $null = $client.Send($replyBytes, $replyBytes.Length, $from)
                }
            }
        } catch {
            $Control.Error = $_.Exception.Message
        } finally {
            if ($client) { $client.Dispose() }
        }
    }).AddArgument($Port).AddArgument($script:ReceiveProtocol.DiscoverMessage).AddArgument($reply).AddArgument($control)

    return @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Runspace = $runspace; Control = $control }
}

function Stop-DiscoveryResponder {
    param([hashtable]$Responder)
    if (-not $Responder) { return }
    $Responder.Control.Stop = $true
    try { $null = $Responder.Handle.AsyncWaitHandle.WaitOne(2000) } catch { }
    try { $Responder.PowerShell.Dispose(); $Responder.Runspace.Dispose() } catch { }
}

function Start-ReceiveSession {
    <#
    .SYNOPSIS
        Prepares this PC to receive a package and returns the session (pairing code, addresses, folder).
    .DESCRIPTION
        Creates a temporary local account whose password is derived from a fresh pairing code, a hidden
        share that only that account can write, inbound firewall rules for SMB and discovery, and a UDP
        responder so the sending PC can find this one. The incoming folder sits on the profile volume
        so the received files can be renamed into place instead of copied again.
        The session is recorded in the registry so a crash is cleaned up on the next start.
    #>
    [CmdletBinding()]
    param(
        [string]$IncomingRoot = (Join-Path ([System.IO.Path]::GetPathRoot($env:USERPROFILE)) $script:ReceiveProtocol.FolderName),
        [string]$Version = $script:MigratorVersion
    )

    Remove-StaleReceiveSession

    $code = New-PairingCode
    $incoming = Join-Path $IncomingRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -Path $incoming -ItemType Directory -Force | Out-Null

    $session = @{
        Code         = $code
        Computer     = $env:COMPUTERNAME
        Addresses    = @(Get-LocalIPv4Addresses)
        IncomingPath = $incoming
        ShareName    = $script:ReceiveProtocol.ShareName
        AccountName  = $script:ReceiveProtocol.AccountName
        Version      = $Version
        FreeBytes    = 0L
        Responder    = $null
    }
    try { $session.FreeBytes = [long]([System.IO.DriveInfo]::new($IncomingRoot.Substring(0, 1))).AvailableFreeSpace } catch { }

    New-Item -Path $script:ReceiveRegistryKey -Force | Out-Null
    Set-ItemProperty -Path $script:ReceiveRegistryKey -Name 'IncomingPath' -Value $incoming
    Set-ItemProperty -Path $script:ReceiveRegistryKey -Name 'StartedUtc' -Value (Get-Date).ToUniversalTime().ToString('o')

    try {
        $password = ConvertTo-SecureString (ConvertTo-ReceivePassword $code) -AsPlainText -Force
        New-LocalUser -Name $session.AccountName -Password $password -AccountNeverExpires -PasswordNeverExpires `
            -UserMayNotChangePassword -Description 'Temporary Win11Migrator transfer account (removed automatically)' -ErrorAction Stop | Out-Null

        $acl = Get-Acl -LiteralPath $incoming
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            "$env:COMPUTERNAME\$($session.AccountName)", 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $incoming -AclObject $acl

        $server = Get-Service -Name LanmanServer -ErrorAction SilentlyContinue
        if ($server -and $server.Status -ne 'Running') { Start-Service -Name LanmanServer -ErrorAction Stop }

        New-SmbShare -Name $session.ShareName -Path $incoming -FullAccess "$env:COMPUTERNAME\$($session.AccountName)" `
            -Description 'Win11Migrator incoming package (temporary)' -ErrorAction Stop | Out-Null

        New-NetFirewallRule -Name $script:ReceiveFirewallRules[0] -DisplayName 'Win11Migrator receive (SMB, temporary)' `
            -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        New-NetFirewallRule -Name $script:ReceiveFirewallRules[1] -DisplayName 'Win11Migrator discovery (temporary)' `
            -Direction Inbound -Protocol UDP -LocalPort $script:ReceiveProtocol.DiscoveryPort -Action Allow -Profile Any -ErrorAction Stop | Out-Null

        $session.Responder = Start-DiscoveryResponder -Session $session
        Write-MigrationLog -Message "Receive session open at $incoming; addresses $($session.Addresses -join ', ')" -Level Info
        return $session
    } catch {
        Write-MigrationLog -Message "Could not open receive session: $($_.Exception.Message)" -Level Error
        Stop-ReceiveSession -Session $session
        throw
    }
}

function Stop-ReceiveSession {
    <#
    .SYNOPSIS
        Removes everything Start-ReceiveSession created except the received files. Safe to run twice.
    #>
    [CmdletBinding()]
    param([hashtable]$Session)

    if ($Session) { Stop-DiscoveryResponder -Responder $Session.Responder }
    $shareName = $script:ReceiveProtocol.ShareName
    $account = $script:ReceiveProtocol.AccountName

    Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:ReceiveFirewallRules) {
        Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    }
    if (Get-LocalUser -Name $account -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $account -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $script:ReceiveRegistryKey -Force -ErrorAction SilentlyContinue
    Write-MigrationLog -Message "Receive session closed" -Level Info
}

function Remove-StaleReceiveSession {
    # A session recorded in the registry means a previous run ended without cleaning up.
    if (Test-Path $script:ReceiveRegistryKey) {
        Write-MigrationLog -Message "Cleaning up a receive session left by an earlier run" -Level Warning
        Stop-ReceiveSession
    }
}
