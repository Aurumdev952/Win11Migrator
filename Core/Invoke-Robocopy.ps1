<#
========================================================================================================
    Title:          Win11Migrator - Robocopy Wrapper
    Filename:       Invoke-Robocopy.ps1
    Description:    Single entry point for every bulk file copy: builds tuned Robocopy arguments, streams
                    output without buffering it, reports live byte progress, and parses the job summary.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:RobocopyDefaultThreads = @{ Local = 16; Network = 16; USB = 4; Cloud = 8 }

function Get-MigrationSetting {
    param($Config, [string]$Name, $Default)
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Name) -and $null -ne $Config[$Name]) { return $Config[$Name] }
    } elseif ($Config -and $Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        return $Config.$Name
    }
    return $Default
}

function Test-UncPath {
    param([string]$Path)
    return [bool]($Path -match '^(\\\\|//)[^\\/]')
}

function New-RobocopyArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('Local', 'USB', 'Network', 'Cloud')]
        [string]$TargetKind = 'Local',
        [hashtable]$Exclusions,
        [switch]$Mirror,
        [switch]$CopySecurity,
        [switch]$ListOnly,
        $Config = $script:Config
    )

    $threadMap = Get-MigrationSetting $Config 'RobocopyThreadsByTarget' $null
    $threads = Get-MigrationSetting $threadMap $TargetKind $script:RobocopyDefaultThreads[$TargetKind]
    $retries = Get-MigrationSetting $Config 'RobocopyRetries' 1
    $wait    = Get-MigrationSetting $Config 'RobocopyWaitSeconds' 1
    $maxMB   = Get-MigrationSetting $Config 'MaxFileSizeMB' 0

    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add($Source)
    $argList.Add($Destination)
    $argList.Add($(if ($Mirror) { '/MIR' } else { '/E' }))
    foreach ($flag in '/XJ', '/NDL', '/NP', '/BYTES', '/NJH') { $argList.Add($flag) }
    $argList.Add("/R:$retries")
    $argList.Add("/W:$wait")
    $argList.Add("/MT:$threads")
    $argList.Add($(if ($CopySecurity) { '/COPY:DATS' } else { '/COPY:DAT' }))
    $argList.Add('/DCOPY:T')

    if ($ListOnly) {
        $argList.Add('/L')
        $argList.Add('/NFL')
    }
    elseif ((Test-UncPath $Source) -or (Test-UncPath $Destination)) {
        $argList.Add('/COMPRESS')
    }
    if ((Get-MigrationSetting $Config 'RobocopyUnbufferedIO' $false) -and -not $ListOnly) {
        $argList.Add('/J')
    }
    if ([long]$maxMB -gt 0) {
        $argList.Add("/MAX:$([long]$maxMB * 1MB)")
    }

    if ($Exclusions -and @($Exclusions.Files).Count -gt 0) {
        $argList.Add('/XF')
        foreach ($f in $Exclusions.Files) { $argList.Add($f) }
    }
    if ($Exclusions -and @($Exclusions.Directories).Count -gt 0) {
        $argList.Add('/XD')
        foreach ($d in $Exclusions.Directories) { $argList.Add($d) }
    }

    return , $argList.ToArray()
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$ArgumentList)
    $quoted = foreach ($a in $ArgumentList) {
        $value = $a
        # A trailing backslash would escape the closing quote; robocopy accepts "C:\." for a root.
        if ($value -match '\\$') {
            $value = if ($value -match '^[A-Za-z]:\\$') { "$value." } else { $value.TrimEnd('\') }
        }
        if ($value -match '[\s"]' -or $value -eq '') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }
    return ($quoted -join ' ')
}

function Get-RobocopyLineBytes {
    # File lines look like "<tab>New File<tab><tab>   12345<tab>name" in every locale; the size is the
    # first purely numeric tab-separated field. Lines starting with '*' are EXTRA entries, not copies.
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith('*') -or $Line.IndexOf("`t") -lt 0) {
        return 0L
    }
    foreach ($field in $Line.Split("`t")) {
        $t = $field.Trim()
        if ($t.Length -gt 0 -and $t -match '^\d+$') { return [long]$t }
    }
    return 0L
}

function ConvertFrom-RobocopySummary {
    # The summary table labels are localized ("Files :" / "Fichiers :"), so rows are read by position:
    # the last block of rows carrying six numeric columns is Dirs, Files, Bytes.
    param([string[]]$Lines)
    $rows = [System.Collections.Generic.List[long[]]]::new()
    foreach ($line in $Lines) {
        if ($line -match '^\s*-{20,}\s*$') { $rows.Clear(); continue }
        $colon = $line.IndexOf(':')
        if ($colon -lt 0) { continue }
        $numbers = @([regex]::Matches($line.Substring($colon + 1), '(?<![\d:.])\d+(?![\d:.])') | ForEach-Object { [long]$_.Value })
        if ($numbers.Count -eq 6) { $rows.Add([long[]]$numbers) }
    }
    if ($rows.Count -lt 3) { return $null }
    $files = $rows[1]; $bytes = $rows[2]
    return [PSCustomObject]@{
        FilesTotal  = $files[0]
        FilesCopied = $files[1]
        FilesFailed = $files[4]
        BytesTotal  = $bytes[0]
        BytesCopied = $bytes[1]
    }
}

function Get-ConsoleOemEncoding {
    try {
        return [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    } catch {
        return [System.Text.Encoding]::Default
    }
}

function Invoke-RobocopyProcess {
    # Streams stdout line by line; only the trailing lines are kept so huge trees never sit in memory.
    param([string[]]$ArgumentList, [scriptblock]$OnLine)

    $psi = [System.Diagnostics.ProcessStartInfo]::new('robocopy.exe')
    $psi.Arguments = ConvertTo-ProcessArgumentString $ArgumentList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = Get-ConsoleOemEncoding

    $tail = [System.Collections.Generic.Queue[string]]::new()
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            if ($OnLine) { & $OnLine $line }
            $tail.Enqueue($line)
            if ($tail.Count -gt 40) { [void]$tail.Dequeue() }
        }
        $process.WaitForExit()
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Tail = $tail.ToArray() }
    } finally {
        $process.Dispose()
    }
}

function Invoke-Robocopy {
    <#
    .SYNOPSIS
        Copies a directory tree with tuned Robocopy flags and reports live byte progress.
    .PARAMETER Progress
        Optional synchronized hashtable. BytesDone is incremented as each file finishes.
    .OUTPUTS
        PSCustomObject with ExitCode, Success (exit code below 8), Files, Bytes, Failed, Tail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('Local', 'USB', 'Network', 'Cloud')]
        [string]$TargetKind = 'Local',
        [hashtable]$Exclusions,
        [switch]$Mirror,
        [switch]$CopySecurity,
        [hashtable]$Progress
    )

    $argList = New-RobocopyArgumentList -Source $Source -Destination $Destination -TargetKind $TargetKind `
        -Exclusions $Exclusions -Mirror:$Mirror -CopySecurity:$CopySecurity

    $onLine = $null
    if ($Progress) {
        $onLine = {
            param($line)
            $b = Get-RobocopyLineBytes $line
            if ($b -gt 0) { $Progress['BytesDone'] = [long]$Progress['BytesDone'] + $b }
        }
    }

    $run = Invoke-RobocopyProcess -ArgumentList $argList -OnLine $onLine
    $summary = ConvertFrom-RobocopySummary $run.Tail

    return [PSCustomObject]@{
        ExitCode = $run.ExitCode
        Success  = ($run.ExitCode -lt 8)
        Files    = if ($summary) { $summary.FilesCopied } else { 0 }
        Bytes    = if ($summary) { $summary.BytesCopied } else { 0 }
        Failed   = if ($summary) { $summary.FilesFailed } else { 0 }
        Tail     = $run.Tail
    }
}

function Measure-RobocopySource {
    <#
    .SYNOPSIS
        Sizes a folder the way Invoke-Robocopy would copy it (same exclusions and size cap) without copying.
    .OUTPUTS
        PSCustomObject with Bytes and Files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [hashtable]$Exclusions
    )

    $phantom = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_measure_$([guid]::NewGuid().ToString('N'))"
    $argList = New-RobocopyArgumentList -Source $Source -Destination $phantom -Exclusions $Exclusions -ListOnly
    $run = Invoke-RobocopyProcess -ArgumentList $argList
    $summary = ConvertFrom-RobocopySummary $run.Tail
    if (-not $summary) { return [PSCustomObject]@{ Bytes = 0L; Files = 0L } }
    return [PSCustomObject]@{ Bytes = $summary.BytesCopied; Files = $summary.FilesCopied }
}
