<#
========================================================================================================
    Title:          Win11Migrator - LAN Receive Protocol
    Filename:       ReceiveProtocol.ps1
    Description:    Constants and pure helpers shared by the receiving PC and the sending PC: pairing codes,
                    the derived share password, discovery messages, and reading an incoming package.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:ReceiveProtocol = @{
    DiscoveryPort   = 50717
    DiscoverMessage = 'W11M-DISCOVER/1'
    ShareName       = 'W11MIncoming$'
    AccountName     = 'W11M_xfer'
    FolderName      = 'Win11MigratorIncoming'
    # No 0/O, 1/I/L: the code is read off one screen and typed on another
    CodeAlphabet    = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
}

function New-PairingCode {
    $bytes = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $alphabet = $script:ReceiveProtocol.CodeAlphabet
    $chars = foreach ($b in $bytes) { $alphabet[$b % $alphabet.Length] }
    return (-join $chars[0..3]) + '-' + (-join $chars[4..7])
}

function ConvertTo-PairingCode {
    # Accepts what a person types: any case, with or without the dash or spaces.
    param([Parameter(Mandatory)][string]$Text)
    $clean = ($Text.ToUpperInvariant() -replace '[^A-Z0-9]', '')
    if ($clean.Length -ne 8) { throw "A pairing code has 8 letters and digits, like ABCD-2345." }
    foreach ($c in $clean.ToCharArray()) {
        if ($script:ReceiveProtocol.CodeAlphabet.IndexOf($c) -lt 0) { throw "'$c' never appears in a pairing code. Check the code shown on the other PC." }
    }
    return $clean.Substring(0, 4) + '-' + $clean.Substring(4)
}

function ConvertTo-ReceivePassword {
    # Both PCs derive the temporary account's password from the code. The fixed parts satisfy
    # Windows complexity rules (upper, lower, digit, symbol) and common 14-character minimums.
    param([Parameter(Mandatory)][string]$PairingCode)
    $code = (ConvertTo-PairingCode $PairingCode) -replace '-', ''
    return "W11m-$code-Xf9!"
}

function ConvertTo-DiscoveryReply {
    param([Parameter(Mandatory)][hashtable]$Session)
    return ([ordered]@{
        Product   = 'Win11Migrator'
        Protocol  = 1
        Computer  = $Session.Computer
        Addresses = @($Session.Addresses)
        Version   = [string]$Session.Version
        FreeBytes = [long]$Session.FreeBytes
    } | ConvertTo-Json -Compress)
}

function ConvertFrom-DiscoveryReply {
    param([Parameter(Mandatory)][string]$Text, [string]$FromAddress)
    try { $reply = $Text | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($reply.Product -ne 'Win11Migrator' -or -not $reply.Computer) { return $null }
    return [PSCustomObject]@{
        Computer  = [string]$reply.Computer
        Address   = if ($FromAddress) { $FromAddress } else { @($reply.Addresses)[0] }
        Addresses = @($reply.Addresses)
        Version   = [string]$reply.Version
        FreeBytes = [long]$reply.FreeBytes
    }
}

function Get-ReceiveSharePath {
    param([Parameter(Mandatory)][string]$Address)
    return "\\$Address\$($script:ReceiveProtocol.ShareName)"
}

function Get-IncomingPackageState {
    <#
    .SYNOPSIS
        What the receiving PC knows about the package arriving in IncomingPath.
    .OUTPUTS
        PSCustomObject with State (Waiting, Receiving, Complete, Failed), PackagePath, ManifestReady,
        SourceComputer, BytesDone, BytesTotal, Phase and Errors.
    #>
    param([Parameter(Mandatory)][string]$IncomingPath)

    $package = Get-ChildItem -LiteralPath $IncomingPath -Directory -Filter 'Win11Migration_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $package) {
        return [PSCustomObject]@{ State = 'Waiting'; PackagePath = $null; ManifestReady = $false; SourceComputer = $null
                                  BytesDone = 0L; BytesTotal = 0L; Phase = ''; Errors = @() }
    }

    $status = $null
    $statusFile = Join-Path $package.FullName 'transfer.json'
    if (Test-Path -LiteralPath $statusFile) {
        try { $status = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    }
    $state = switch ($status.State) {
        'Complete' { 'Complete' }
        'Failed'   { 'Failed' }
        default    { 'Receiving' }
    }
    return [PSCustomObject]@{
        State          = $state
        PackagePath    = $package.FullName
        ManifestReady  = (Test-Path -LiteralPath (Join-Path $package.FullName 'manifest.json'))
        SourceComputer = if ($status) { [string]$status.ComputerName } else { $null }
        BytesDone      = if ($status) { [long]$status.BytesDone } else { 0L }
        BytesTotal     = if ($status) { [long]$status.BytesTotal } else { 0L }
        Phase          = if ($status) { [string]$status.Phase } else { '' }
        Errors         = if ($status) { @($status.Errors) } else { @() }
    }
}
