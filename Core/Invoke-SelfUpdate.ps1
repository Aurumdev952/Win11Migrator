<#
========================================================================================================
    Title:          Win11Migrator - Self Update
    Filename:       Invoke-SelfUpdate.ps1
    Description:    Checks this build's GitHub releases for a newer version and installs it after verifying
                    the download: by Authenticode signer when one is configured, otherwise by the SHA-256
                    published with the release.
========================================================================================================
#>

#Requires -Version 5.1

function Get-UpdateSettings {
    param([string]$Root = $script:MigratorRoot)
    $settings = Get-Content (Join-Path $Root 'Config\AppSettings.json') -Raw | ConvertFrom-Json
    return [PSCustomObject]@{
        Repository    = [string]$settings.UpdateRepository
        SignerSubject = [string]$settings.UpdateSignerSubject
    }
}

function Select-UpdateAsset {
    # The MSI upgrades an installed copy in place; the older setup .exe is accepted for releases that predate it.
    param($Assets)
    $msi = $Assets | Where-Object { $_.name -match '^Win11Migrator-[\d.]+-x64\.msi$' } | Select-Object -First 1
    if ($msi) { return $msi }
    return $Assets | Where-Object { $_.name -match '^Win11Migrator[-_]Setup.*\.exe$' } | Select-Object -First 1
}

function Get-ExpectedSha256 {
    # SHA256SUMS.txt lines look like "<hex>  <file name>"
    param([string]$SumsText, [string]$FileName)
    foreach ($line in ($SumsText -split "`r?`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $FileName) { return $Matches[1].ToUpperInvariant() }
    }
    return $null
}

function Get-Win11MigratorUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$CurrentVersion,
        [string]$Repository = (Get-UpdateSettings).Repository
    )

    try {
        if (-not $Repository) { throw 'No UpdateRepository is configured in AppSettings.json.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'Win11Migrator-Updater' }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -UseBasicParsing -TimeoutSec 8
        $latest = [version]([string]$release.tag_name -replace '^[vV]', '')
        $asset = Select-UpdateAsset $release.assets
        $sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
        [pscustomobject]@{
            CurrentVersion  = $CurrentVersion
            LatestVersion   = $latest
            UpdateAvailable = ($latest -gt $CurrentVersion -and $null -ne $asset)
            DownloadUrl     = if ($asset) { [string]$asset.browser_download_url } else { $null }
            FileName        = if ($asset) { [string]$asset.name } else { $null }
            SumsUrl         = if ($sums) { [string]$sums.browser_download_url } else { $null }
        }
    } catch {
        [pscustomobject]@{ CurrentVersion = $CurrentVersion; LatestVersion = $null; UpdateAvailable = $false; Error = $_.Exception.Message }
    }
}

function Test-UpdateFile {
    <#
    .SYNOPSIS
        Throws unless the downloaded installer is trustworthy: signed by the configured publisher, or,
        when no signer is configured (unsigned builds), matching the SHA-256 published with the release.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Update,
        [string]$SignerSubject = (Get-UpdateSettings).SignerSubject
    )
    if ($SignerSubject) {
        $signature = Get-AuthenticodeSignature -FilePath $Path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch [regex]::Escape($SignerSubject)) {
            throw "The downloaded update is not validly signed by '$SignerSubject'."
        }
        return
    }
    if (-not $Update.SumsUrl) { throw 'The release has no SHA256SUMS.txt, so the download cannot be verified.' }
    $sums = (Invoke-WebRequest -Uri $Update.SumsUrl -UseBasicParsing -TimeoutSec 30).Content
    if ($sums -is [byte[]]) { $sums = [System.Text.Encoding]::UTF8.GetString($sums) }
    $expected = Get-ExpectedSha256 -SumsText $sums -FileName $Update.FileName
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $expected -or $expected -ne $actual) { throw 'The downloaded update does not match the checksum published with the release.' }
}

function Invoke-Win11MigratorSelfUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][version]$CurrentVersion, [switch]$Automatic)

    $registryPath = 'HKCU:\SOFTWARE\AuthorityGate\Win11Migrator'
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    if ($Automatic) {
        $lastCheck = (Get-ItemProperty -Path $registryPath -Name LastUpdateCheck -ErrorAction SilentlyContinue).LastUpdateCheck
        if ($lastCheck) {
            try { if ((Get-Date) - [datetime]$lastCheck -lt [timespan]::FromHours(24)) { return } } catch {}
        }
    }
    Set-ItemProperty -Path $registryPath -Name LastUpdateCheck -Value (Get-Date).ToString('o')

    $update = Get-Win11MigratorUpdate -CurrentVersion $CurrentVersion
    if (-not $update.UpdateAvailable) {
        if (-not $Automatic) {
            $message = if ($update.Error) { "The update service could not be reached.`n`n$($update.Error)" } else { "Win11Migrator $CurrentVersion is current." }
            [System.Windows.MessageBox]::Show($message, 'Win11Migrator Update', 'OK', 'Information') | Out-Null
        }
        return
    }

    $answer = [System.Windows.MessageBox]::Show("Win11Migrator $($update.LatestVersion) is available. Download and install it now?", 'Win11Migrator Update', 'YesNo', 'Information')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $destination = Join-Path $env:TEMP $update.FileName
    Invoke-WebRequest -Uri $update.DownloadUrl -OutFile $destination -UseBasicParsing -TimeoutSec 180
    try {
        Test-UpdateFile -Path $destination -Update $update
    } catch {
        Remove-Item $destination -Force -ErrorAction SilentlyContinue
        throw
    }
    if ($destination -like '*.msi') {
        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$destination`"" -Verb RunAs
    } else {
        Start-Process -FilePath $destination -Verb RunAs
    }
}
