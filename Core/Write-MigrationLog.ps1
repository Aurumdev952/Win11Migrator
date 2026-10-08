<#
========================================================================================================
    Title:          Win11Migrator - Migration Logging Engine
    Filename:       Write-MigrationLog.ps1
    Description:    Provides structured logging with level-based filtering and file output for migration operations.
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
    Logging infrastructure: writes to file, verbose stream, and a queue for the GUI.
#>

# Global log queue for GUI consumption
if (-not $script:LogQueue) {
    $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}

# Session ID for log correlation across phases
if (-not $script:LogSessionId) {
    $script:LogSessionId = [guid]::NewGuid().ToString('N').Substring(0, 8)
}

if (-not $script:LogFileMutex) {
    $script:LogFileMutex = [System.Threading.Mutex]::new($false, 'Win11Migrator.LogFile')
}

# Silent mode flag (set by -Silent switch)
if (-not (Test-Path variable:script:SilentMode)) {
    $script:SilentMode = $false
}

function Write-MigrationLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Success')]
        [string]$Level = 'Info',

        [string]$LogPath,

        [ValidateSet('Text', 'JSON')]
        [string]$Format
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to file if path available (guaranteed write, not just queue-based)
    $effectivePath = if ($LogPath) { $LogPath }
                     elseif ($script:Config -and $script:Config.LogPath) { $script:Config.LogPath }
                     else { $null }

    if ($effectivePath) {
        # Export, import and background workers run in separate runspaces that share one log file.
        $lockTaken = $false
        try {
            try { $lockTaken = $script:LogFileMutex.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $lockTaken = $true }

            # Determine format
            $effectiveFormat = if ($Format) { $Format }
                              elseif ($script:Config -and $script:Config.LogFormat) { $script:Config.LogFormat }
                              else { 'Text' }

            if ($effectiveFormat -eq 'JSON') {
                $jsonEntry = @{
                    timestamp = (Get-Date).ToString('o')
                    level     = $Level
                    message   = $Message
                    sessionId = $script:LogSessionId
                } | ConvertTo-Json -Compress
                Add-Content -Path $effectivePath -Value $jsonEntry -ErrorAction Stop
            } else {
                Add-Content -Path $effectivePath -Value $logEntry -ErrorAction Stop
            }

            # Log rotation: check file size against max (default 10MB)
            $maxSizeBytes = if ($script:Config -and $script:Config.LogMaxSizeMB) {
                $script:Config.LogMaxSizeMB * 1MB
            } else { 10MB }

            $logFile = Get-Item $effectivePath -ErrorAction SilentlyContinue
            if ($logFile -and $logFile.Length -gt $maxSizeBytes) {
                $rotatedPath = "$effectivePath.$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
                Move-Item -Path $effectivePath -Destination $rotatedPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # Silently continue if log file is locked
        } finally {
            if ($lockTaken) { $script:LogFileMutex.ReleaseMutex() }
        }
    }

    # Push to GUI queue
    $script:LogQueue.Enqueue($logEntry)

    # Write to appropriate stream (suppressed in silent mode)
    if (-not $script:SilentMode) {
        switch ($Level) {
            'Error'   { Write-Error $Message -ErrorAction Continue }
            'Warning' { Write-Warning $Message }
            'Debug'   { Write-Verbose $Message }
            'Success' { Write-Host $logEntry -ForegroundColor Green }
            default   { Write-Verbose $logEntry }
        }
    }
}

function Get-LogEntries {
    [CmdletBinding()]
    param(
        [int]$MaxEntries = 100
    )

    $entries = [System.Collections.Generic.List[string]]::new()
    $entry = $null
    while ($entries.Count -lt $MaxEntries -and $script:LogQueue.TryDequeue([ref]$entry)) {
        $entries.Add($entry)
    }
    # The comma keeps a single entry an array; otherwise $entries[0] would be its first character
    return , $entries.ToArray()
}

function Clear-LogQueue {
    while ($script:LogQueue.Count -gt 0) {
        $null = $script:LogQueue.TryDequeue([ref]$null)
    }
}

function Add-ProgressLog {
    <#
    .SYNOPSIS
        Appends a line to a progress hashtable's Log (shown by the GUI) and echoes it for the CLI when Echo is set.
    #>
    param([hashtable]$Progress, [string]$Message)
    if ($Progress -and $null -ne $Progress.Log) { $null = $Progress.Log.Add($Message) }
    if ($Progress -and $Progress.Echo) { Write-Host $Message }
}
