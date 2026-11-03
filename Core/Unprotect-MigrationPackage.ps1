<#
========================================================================================================
    Title:          Win11Migrator - Migration Package Decryption
    Filename:       Unprotect-MigrationPackage.ps1
    Description:    Decrypts .w11mcrypt files back into migration package directories using AES-256-CBC.
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
    Decrypts a .w11mcrypt encrypted migration package and extracts it to a directory.
.DESCRIPTION
    Reads the custom binary format, extracts salt and IV, derives the AES-256
    key using PBKDF2 (100000 iterations), decrypts the payload, and extracts
    the resulting zip archive to the specified output directory.
.OUTPUTS
    [hashtable] with OutputDirectory and Success keys.
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Unprotect-MigrationPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedFile,

        [Parameter(Mandatory)]
        [securestring]$Password,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    Write-MigrationLog -Message "Starting decryption of: $EncryptedFile" -Level Info

    # Validate encrypted file exists
    if (-not (Test-Path -Path $EncryptedFile -PathType Leaf)) {
        Write-MigrationLog -Message "Encrypted file not found: $EncryptedFile" -Level Error
        return @{ OutputDirectory = ''; Success = $false }
    }

    $tempZip = $null

    try {
        $inputStream = [System.IO.File]::OpenRead($EncryptedFile)
        try {
            $reader = New-Object System.IO.BinaryReader($inputStream)

            # ---- Step 1: Read and verify magic bytes ----
            $magic = $reader.ReadBytes(8)
            $expectedMagic = [byte[]]@(0x57, 0x31, 0x31, 0x4D, 0x43, 0x52, 0x50, 0x54)
            $magicValid = ($magic.Length -eq 8)
            for ($i = 0; $magicValid -and $i -lt 8; $i++) {
                if ($magic[$i] -ne $expectedMagic[$i]) { $magicValid = $false }
            }
            if (-not $magicValid) {
                Write-MigrationLog -Message "Invalid file format: missing W11MCRYPT magic bytes" -Level Error
                return @{ OutputDirectory = ''; Success = $false }
            }

            # ---- Step 2: Read version, salt, IV ----
            $version = $reader.ReadUInt32()
            if ($version -ne 1) {
                Write-MigrationLog -Message "Unsupported encryption format version: $version" -Level Error
                return @{ OutputDirectory = ''; Success = $false }
            }
            $saltLength = $reader.ReadUInt32()
            $salt       = $reader.ReadBytes([int]$saltLength)
            $ivLength   = $reader.ReadUInt32()
            $iv         = $reader.ReadBytes([int]$ivLength)
            Write-MigrationLog -Message "File header parsed: version=$version, saltLen=$saltLength, ivLen=$ivLength" -Level Debug

            # ---- Step 3: Derive key using PBKDF2 ----
            $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            )
            $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                $passwordPlain, $salt, 100000
            )
            try {
                $key       = $deriveBytes.GetBytes(32)
                $derivedIv = $deriveBytes.GetBytes(16)
            } finally {
                $deriveBytes.Dispose()
            }
            $passwordPlain = $null

            # ---- Step 4: Stream-decrypt the remainder of the file into a temp zip ----
            $tempZip = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.IO.Path]::GetRandomFileName() + '.zip')
            $aes = New-Object System.Security.Cryptography.AesManaged
            $aes.KeySize   = 256
            $aes.BlockSize = 128
            $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key       = $key
            $aes.IV        = $iv
            $zipStream = [System.IO.File]::Create($tempZip)
            $cryptoStream = New-Object System.Security.Cryptography.CryptoStream(
                $inputStream, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
            try {
                $cryptoStream.CopyTo($zipStream, 4MB)
            } catch [System.Security.Cryptography.CryptographicException] {
                Write-MigrationLog -Message "Decryption failed: incorrect password or corrupted file" -Level Error
                return @{ OutputDirectory = ''; Success = $false }
            } finally {
                $zipStream.Dispose()
                try { $cryptoStream.Dispose() } catch {}
                $aes.Dispose()
            }
        } finally {
            $inputStream.Dispose()
        }

        # Validate the zip is well-formed (catches wrong-password garbage)
        try {
            $testZip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
            $entryCount = $testZip.Entries.Count
            $testZip.Dispose()
            Write-MigrationLog -Message "Zip archive validated: $entryCount entries" -Level Debug
        } catch {
            Write-MigrationLog -Message "Decryption produced invalid archive: incorrect password or corrupted file" -Level Error
            return @{ OutputDirectory = ''; Success = $false }
        }

        # ---- Step 6: Extract zip to output directory ----
        if (-not (Test-Path -Path $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }

        [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $OutputDirectory)

        Write-MigrationLog -Message "Decryption and extraction complete: $OutputDirectory" -Level Success

        return @{
            OutputDirectory = $OutputDirectory
            Success         = $true
        }

    } catch {
        Write-MigrationLog -Message "Decryption failed: $($_.Exception.Message)" -Level Error
        return @{
            OutputDirectory = ''
            Success         = $false
        }
    } finally {
        # ---- Step 7: Clean up temp zip ----
        if ($tempZip -and (Test-Path -Path $tempZip)) {
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
            Write-MigrationLog -Message "Cleaned up temporary zip file" -Level Debug
        }

        # Clear sensitive byte arrays
        if ($key)       { [Array]::Clear($key, 0, $key.Length) }
        if ($derivedIv) { [Array]::Clear($derivedIv, 0, $derivedIv.Length) }
    }
}

function Find-EncryptedPackage {
    <#
    .SYNOPSIS
        The .w11mcrypt file a user pointed at: the file itself, or the newest one in a folder without a manifest.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ($Path -like '*.w11mcrypt') { return (Resolve-Path -LiteralPath $Path).ProviderPath }
        return $null
    }
    if (Test-Path -LiteralPath (Join-Path $Path 'manifest.json')) { return $null }
    $file = Get-ChildItem -LiteralPath $Path -Filter '*.w11mcrypt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Expand-EncryptedPackage {
    <#
    .SYNOPSIS
        Decrypts a .w11mcrypt into OutputRoot\<package name> and returns that folder, ready to import.
    #>
    param(
        [Parameter(Mandatory)][string]$EncryptedFile,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$OutputRoot
    )
    $target = Join-Path $OutputRoot ([System.IO.Path]::GetFileNameWithoutExtension($EncryptedFile))
    if (Test-Path -LiteralPath (Join-Path $target 'manifest.json')) { return $target }
    $result = Unprotect-MigrationPackage -EncryptedFile $EncryptedFile -Password $Password -OutputDirectory $target
    if (-not $result.Success) { throw "The package could not be decrypted. Check the password." }
    return $target
}
