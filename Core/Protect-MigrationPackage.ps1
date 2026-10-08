<#
========================================================================================================
    Title:          Win11Migrator - Migration Package Encryption
    Filename:       Protect-MigrationPackage.ps1
    Description:    Provides AES-256-CBC encryption for migration packages to secure data in transit.
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
    Encrypts a migration package directory into a single .w11mcrypt file using AES-256-CBC.
.DESCRIPTION
    Compresses the specified package directory to a temporary zip, then encrypts
    it with AES-256-CBC using a password-derived key (PBKDF2, 100000 iterations).
    The output file uses a custom binary format with magic bytes, salt, IV, and
    the encrypted payload.
.OUTPUTS
    [hashtable] with OutputFile, SizeBytes, and Success keys.
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Protect-MigrationPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [securestring]$Password,

        [Parameter()]
        [string]$OutputFile
    )

    Write-MigrationLog -Message "Starting encryption of migration package: $PackagePath" -Level Info

    # Validate source directory
    if (-not (Test-Path -Path $PackagePath -PathType Container)) {
        Write-MigrationLog -Message "Package directory not found: $PackagePath" -Level Error
        return @{ OutputFile = ''; SizeBytes = 0; Success = $false }
    }

    # Auto-generate output file path if not specified
    if (-not $OutputFile) {
        $parentDir = Split-Path -Path $PackagePath -Parent
        $dirName   = Split-Path -Path $PackagePath -Leaf
        $OutputFile = Join-Path -Path $parentDir -ChildPath "$dirName.w11mcrypt"
    }

    $tempZip = $null

    try {
        # ---- Step 1: Compress to temporary zip ----
        $tempZip = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.IO.Path]::GetRandomFileName() + '.zip')
        Write-MigrationLog -Message "Compressing package to temporary zip: $tempZip" -Level Debug

        if (Test-Path -Path $tempZip) {
            Remove-Item -Path $tempZip -Force
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($PackagePath, $tempZip)

        # ---- Step 2: Generate salt ----
        $salt = New-Object byte[] 32
        $rng  = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        try {
            $rng.GetBytes($salt)
        } finally {
            $rng.Dispose()
        }

        # ---- Step 3: Derive key and IV via PBKDF2 ----
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        )
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $passwordPlain, $salt, 100000
        )
        try {
            $key = $deriveBytes.GetBytes(32)  # AES-256
            $iv  = $deriveBytes.GetBytes(16)  # CBC IV
        } finally {
            $deriveBytes.Dispose()
        }
        $passwordPlain = $null

        # ---- Step 4: Write header, then stream the zip through AES-256-CBC ----
        # Streaming keeps memory flat; multi-GB packages exceed what a single byte array can hold.
        $aes = New-Object System.Security.Cryptography.AesManaged
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $key
        $aes.IV        = $iv
        $outputStream = [System.IO.File]::Create($OutputFile)
        try {
            $writer = New-Object System.IO.BinaryWriter($outputStream)
            $writer.Write([byte[]]@(0x57, 0x31, 0x31, 0x4D, 0x43, 0x52, 0x50, 0x54))  # W11MCRPT
            $writer.Write([uint32]1)
            $writer.Write([uint32]$salt.Length)
            $writer.Write($salt)
            $writer.Write([uint32]$iv.Length)
            $writer.Write($iv)
            $writer.Flush()

            $cryptoStream = New-Object System.Security.Cryptography.CryptoStream(
                $outputStream, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
            $zipStream = [System.IO.File]::OpenRead($tempZip)
            try {
                $zipStream.CopyTo($cryptoStream, 4MB)
                $cryptoStream.FlushFinalBlock()
            } finally {
                $zipStream.Dispose()
                $cryptoStream.Dispose()
            }
        } finally {
            $outputStream.Dispose()
            $aes.Dispose()
        }

        $outputFileInfo = Get-Item -Path $OutputFile
        $sizeBytes = $outputFileInfo.Length

        Write-MigrationLog -Message "Encryption complete: $OutputFile ($sizeBytes bytes)" -Level Success

        return @{
            OutputFile = $OutputFile
            SizeBytes  = $sizeBytes
            Success    = $true
        }

    } catch {
        Write-MigrationLog -Message "Encryption failed: $($_.Exception.Message)" -Level Error
        return @{
            OutputFile = ''
            SizeBytes  = 0
            Success    = $false
        }
    } finally {
        # ---- Step 6: Clean up temp zip ----
        if ($tempZip -and (Test-Path -Path $tempZip)) {
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
            Write-MigrationLog -Message "Cleaned up temporary zip file" -Level Debug
        }

        # Clear sensitive byte arrays
        if ($key) { [Array]::Clear($key, 0, $key.Length) }
        if ($iv)  { [Array]::Clear($iv, 0, $iv.Length) }
    }
}
