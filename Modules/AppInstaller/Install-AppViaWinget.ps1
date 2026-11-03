<#
========================================================================================================
    Title:          Win11Migrator - Winget Application Installer
    Filename:       Install-AppViaWinget.ps1
    Description:    Installs an application using the Windows Package Manager (winget) with timeout and error handling.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Installs an application using the Windows Package Manager (winget).

.DESCRIPTION
    Runs winget install for a given MigrationApp that has a PackageId set.
    Captures the exit code and stdout/stderr, applies a configurable timeout,
    and updates InstallStatus / InstallError on the returned object.

.PARAMETER App
    A [MigrationApp] instance whose PackageId property identifies the winget package.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the installer to finish.
    Defaults to the SilentInstallTimeout value in AppSettings.json (600).

.OUTPUTS
    [MigrationApp] - the same object with InstallStatus and InstallError updated.
#>

function Install-AppViaWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App,

        [int]$TimeoutSeconds = 600
    )

    Write-MigrationLog -Message "Winget: Starting install of '$($App.Name)' (PackageId: $($App.PackageId))" -Level Info

    # -----------------------------------------------------------------
    # Pre-flight validation
    # -----------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($App.PackageId)) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'PackageId is empty. Cannot install via winget.'
        Write-MigrationLog -Message "Winget: $($App.InstallError)" -Level Error
        return $App
    }

    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetPath) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'winget is not available on this system.'
        Write-MigrationLog -Message "Winget: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Build arguments
    # -----------------------------------------------------------------
    # --exact stops a partial ID from matching a different package; Store IDs look like 9NBLGGH4NNS1 or XP...
    $wingetSource = if ($App.PackageId -match '^(9[A-Z0-9]{11}|XP[A-Z0-9]{10,})$') { 'msstore' } else { 'winget' }
    $arguments = @(
        'install'
        '--id'
        $App.PackageId
        '--exact'
        '--source'
        $wingetSource
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
        '--silent'
        '--force'
    )

    # -----------------------------------------------------------------
    # Execute with timeout via Start-Process
    # -----------------------------------------------------------------
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $processParams = @{
            FilePath               = $wingetPath.Source
            ArgumentList           = $arguments
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
            NoNewWindow            = $true
            PassThru               = $true
        }

        Write-MigrationLog -Message "Winget: Executing: winget $($arguments -join ' ')" -Level Debug

        $process = Start-Process @processParams
        $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            # Process exceeded timeout -- kill it
            try { $process.Kill() } catch { <# best effort #> }
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Installation timed out after $TimeoutSeconds seconds."
            Write-MigrationLog -Message "Winget: $($App.InstallError) (PackageId: $($App.PackageId))" -Level Error
            return $App
        }

        $exitCode = $process.ExitCode
        $stdout   = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr   = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { '' }

        Write-MigrationLog -Message "Winget: Exit code $exitCode for '$($App.PackageId)'" -Level Debug

        # -----------------------------------------------------------------
        # Evaluate result
        # -----------------------------------------------------------------
        # winget exit codes: 0 = success, -1978335189 = already installed,
        # other nonzero = failure.
        $alreadyInstalledCode = -1978335189

        if ($exitCode -eq 0 -or $exitCode -eq $alreadyInstalledCode) {
            $App.InstallStatus = 'Success'
            $App.InstallError  = $null

            if ($exitCode -eq $alreadyInstalledCode) {
                Write-MigrationLog -Message "Winget: '$($App.Name)' was already installed." -Level Info
            } else {
                Write-MigrationLog -Message "Winget: '$($App.Name)' installed successfully." -Level Success
            }
        } else {
            $App.InstallStatus = 'Failed'

            # Build a meaningful error message from available output
            $errorDetail = if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $stderr.Trim()
            } elseif (-not [string]::IsNullOrWhiteSpace($stdout)) {
                $stdout.Trim()
            } else {
                "winget exited with code $exitCode"
            }

            # Truncate very long output to keep logs manageable
            if ($errorDetail.Length -gt 500) {
                $errorDetail = $errorDetail.Substring(0, 500) + '...(truncated)'
            }
            $App.InstallError = "Exit code $exitCode - $errorDetail"
            Write-MigrationLog -Message "Winget: Failed to install '$($App.Name)': $($App.InstallError)" -Level Error
        }
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Exception during winget install: $($_.Exception.Message)"
        Write-MigrationLog -Message "Winget: $($App.InstallError)" -Level Error
    }
    finally {
        # Clean up temp files
        foreach ($f in @($stdoutFile, $stderrFile)) {
            if (Test-Path $f) {
                Remove-Item $f -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $App
}
