<#
========================================================================================================
    Title:          Win11Migrator - Remote Access Validator
    Filename:       Test-RemoteAccess.ps1
    Description:    Validates connectivity and permissions to a target machine for direct network transfer.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Tests remote connectivity and access to a target computer.
.DESCRIPTION
    Validates that the target machine is reachable and that the provided credentials
    have sufficient permissions for migration. Tests ping, WinRM, admin share (C$),
    and PSSession connectivity in sequence.
.PARAMETER ComputerName
    Hostname or IP address of the target computer.
.PARAMETER Credential
    PSCredential for authenticating to the target machine.
.PARAMETER TimeoutMs
    Timeout in milliseconds for each connectivity test. Defaults to 5000.
.OUTPUTS
    [hashtable] With Reachable, WinRMAvailable, AdminShareAvailable, PSSessionAvailable,
    ErrorMessage keys.
.EXAMPLE
    $cred = Get-Credential
    $result = Test-RemoteAccess -ComputerName 'TARGET-PC' -Credential $cred
#>

function Test-RemoteAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [string]$TargetUserName,

        [int]$TimeoutMs = 5000
    )

    Write-MigrationLog -Message "Testing remote access to '$ComputerName'" -Level Info

    $result = @{
        ComputerName       = $ComputerName
        Reachable          = $false
        WinRMAvailable     = $false
        AdminShareAvailable = $false
        PSSessionAvailable = $false
        ErrorMessage       = ''
    }

    $errors = @()

    # -------------------------------------------------------------------------
    # 1. Ping test
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Testing ping to '$ComputerName'" -Level Debug
    try {
        $pingResult = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop
        $result.Reachable = $pingResult
        if ($pingResult) {
            Write-MigrationLog -Message "Ping to '$ComputerName' succeeded" -Level Info
        } else {
            $errors += "Ping failed: Host did not respond."
            Write-MigrationLog -Message "Ping to '$ComputerName' failed" -Level Warning
        }
    } catch {
        $errors += "Ping failed: $($_.Exception.Message)"
        Write-MigrationLog -Message "Ping test error: $($_.Exception.Message)" -Level Warning
    }

    # Many PCs drop ping at the firewall while SMB still works, so a failed ping does not stop the other tests

    # -------------------------------------------------------------------------
    # 2. WinRM test
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Testing WinRM on '$ComputerName'" -Level Debug
    try {
        $wsmanResult = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        if ($wsmanResult) {
            $result.WinRMAvailable = $true
            Write-MigrationLog -Message "WinRM is available on '$ComputerName'" -Level Info
        }
    } catch {
        $errors += "WinRM unavailable: $($_.Exception.Message)"
        Write-MigrationLog -Message "WinRM test failed: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # 3. Admin share test (\\ComputerName\C$)
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Testing admin share access on '$ComputerName'" -Level Debug
    try {
        # Map a temporary PSDrive with the provided credential to test C$
        $sharePath = "\\$ComputerName\C$"
        $testDriveName = "MigratorTest_$(Get-Random)"

        $null = New-PSDrive -Name $testDriveName -PSProvider FileSystem -Root $sharePath -Credential $Credential -ErrorAction Stop
        $result.AdminShareAvailable = $true
        Write-MigrationLog -Message "Admin share ($sharePath) is accessible" -Level Info

        # Clean up test drive
        Remove-PSDrive -Name $testDriveName -Force -ErrorAction SilentlyContinue
    } catch {
        $errors += "Admin share (C$) not accessible: $($_.Exception.Message)"
        Write-MigrationLog -Message "Admin share test failed: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # 4. PSSession test
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Testing PSSession to '$ComputerName'" -Level Debug
    $session = $null
    try {
        $sessionOption = New-PSSessionOption -OpenTimeout $TimeoutMs -OperationTimeout $TimeoutMs
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -SessionOption $sessionOption -ErrorAction Stop
        $result.PSSessionAvailable = $true
        Write-MigrationLog -Message "PSSession to '$ComputerName' established successfully" -Level Info
    } catch {
        $errors += "PSSession failed: $($_.Exception.Message)"
        Write-MigrationLog -Message "PSSession test failed: $($_.Exception.Message)" -Level Warning
    } finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }

    # -------------------------------------------------------------------------
    # Build error message with troubleshooting tips
    # -------------------------------------------------------------------------
    if (-not $result.WinRMAvailable -and -not $result.AdminShareAvailable -and -not $result.PSSessionAvailable) {
        $tips = @(
            'Troubleshooting tips:'
            '- Run "Enable-PSRemoting -Force" on the target machine as Administrator.'
            '- Ensure Windows Firewall allows WinRM (TCP 5985/5986) and File Sharing (TCP 445).'
            '- Verify the credentials have local Administrator rights on the target.'
            '- On workgroup machines, ensure the target has: Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*"'
            '- Check that the network profile is set to Private, not Public.'
        )
        $result.ErrorMessage = ($errors -join ' ') + ' ' + ($tips -join ' ')
        Write-MigrationLog -Message "All remote access methods failed for '$ComputerName'" -Level Error
    } elseif ($errors.Count -gt 0) {
        $result.ErrorMessage = $errors -join ' '
    }

    $accessMethods = @()
    if ($result.WinRMAvailable)     { $accessMethods += 'WinRM' }
    if ($result.AdminShareAvailable) { $accessMethods += 'AdminShare' }
    if ($result.PSSessionAvailable) { $accessMethods += 'PSSession' }
    Write-MigrationLog -Message "Remote access test complete for '$ComputerName': Available methods: $($accessMethods -join ', ')" -Level Info

    return $result
}
