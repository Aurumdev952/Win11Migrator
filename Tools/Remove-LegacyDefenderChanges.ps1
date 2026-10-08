<#
.SYNOPSIS
    Undoes the Microsoft Defender and execution-policy changes made by Win11Migrator.bat before 1.1.0.
.DESCRIPTION
    Earlier launchers turned off Defender real-time protection, excluded every .ps1/.psm1/.psd1 file and
    powershell.exe from scanning, excluded the install and source folders, and set the machine-wide
    execution policy to Bypass. This script removes exactly those exclusions and turns real-time
    protection back on. Run it elevated on every PC where an older version was used.
    Use -WhatIf to see what would change. Execution policy is only reset with -ResetExecutionPolicy,
    because an administrator may have set it deliberately.
.EXAMPLE
    .\Remove-LegacyDefenderChanges.ps1 -WhatIf
.EXAMPLE
    .\Remove-LegacyDefenderChanges.ps1 -ResetExecutionPolicy
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ResetExecutionPolicy
)

$prefs = Get-MpPreference

foreach ($ext in '.ps1', '.psm1', '.psd1') {
    if ($prefs.ExclusionExtension -contains $ext -and $PSCmdlet.ShouldProcess("Defender extension exclusion $ext", 'Remove')) {
        Remove-MpPreference -ExclusionExtension $ext
    }
}

foreach ($proc in @($prefs.ExclusionProcess | Where-Object { $_ -match '(^|\\)powershell\.exe$' })) {
    if ($PSCmdlet.ShouldProcess("Defender process exclusion $proc", 'Remove')) {
        Remove-MpPreference -ExclusionProcess $proc
    }
}

foreach ($path in @($prefs.ExclusionPath | Where-Object { $_ -match 'Win11Migrator' })) {
    if ($PSCmdlet.ShouldProcess("Defender path exclusion $path", 'Remove')) {
        Remove-MpPreference -ExclusionPath $path
    }
}

if ($prefs.DisableRealtimeMonitoring -and $PSCmdlet.ShouldProcess('Defender real-time protection', 'Turn on')) {
    Set-MpPreference -DisableRealtimeMonitoring $false
}

if ($ResetExecutionPolicy -and (Get-ExecutionPolicy -Scope LocalMachine) -eq 'Bypass' -and
    $PSCmdlet.ShouldProcess('LocalMachine execution policy Bypass', 'Reset to Windows default')) {
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Undefined -Force
}

Write-Host 'Done. Current Defender exclusions:' -ForegroundColor Green
$after = Get-MpPreference
[PSCustomObject]@{
    RealTimeProtection = -not $after.DisableRealtimeMonitoring
    Extensions         = ($after.ExclusionExtension -join ', ')
    Processes          = ($after.ExclusionProcess -join ', ')
    Paths              = ($after.ExclusionPath -join ', ')
} | Format-List
