#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for exclusion resolution and the config rules that guard it.
#>

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    . "$ProjectRoot/Core/Invoke-Robocopy.ps1"
    . "$ProjectRoot/Core/Get-MigrationExclusions.ps1"
    . "$ProjectRoot/Core/Write-MigrationLog.ps1"
    . "$ProjectRoot/Core/Test-MigrationConfig.ps1"
    $script:SilentMode = $true
}

Describe 'Get-MigrationExclusions' {
    It 'ships the developer junk folders as defaults' {
        $settings = Get-Content "$ProjectRoot/Config/AppSettings.json" -Raw | ConvertFrom-Json
        $ex = Get-MigrationExclusions -Config $settings -MigrationProfile $null
        foreach ($dir in 'node_modules', '.venv', '__pycache__') { $ex.Directories | Should -Contain $dir }
        $ex.Files | Should -Contain '*.pyc'
    }

    It 'adds profile and user exclusions after the defaults, case-insensitively de-duplicated' {
        $config = @{ ExcludeDirectories = @('node_modules'); ExcludeFilePatterns = @('*.tmp') }
        $migrationProfile = [PSCustomObject]@{ Exclusions = [PSCustomObject]@{ Directories = @('target', 'NODE_MODULES'); Files = @('*.bak') } }
        $ex = Get-MigrationExclusions -Config $config -MigrationProfile $migrationProfile -ExtraDirectories 'build\', ' dist ' -ExtraFiles '*.TMP', '*.iso'
        $ex.Directories | Should -Be @('node_modules', 'target', 'build', 'dist')
        $ex.Files | Should -Be @('*.tmp', '*.bak', '*.iso')
    }

    It 'returns empty lists when nothing is configured' {
        $ex = Get-MigrationExclusions -Config @{} -MigrationProfile $null
        @($ex.Directories).Count | Should -Be 0
        @($ex.Files).Count | Should -Be 0
    }
}

Describe 'Test-PathExcluded' {
    BeforeAll {
        $ex = @{ Directories = @('node_modules', '.venv', '__pycache__'); Files = @('*.pyc', '~$*') }
    }

    It 'excludes files under an excluded folder at any depth' {
        Test-PathExcluded -RelativePath 'proj\web\node_modules\react\index.js' -Exclusions $ex | Should -BeTrue
        Test-PathExcluded -RelativePath 'proj/.venv/lib/site.py' -Exclusions $ex | Should -BeTrue
    }

    It 'excludes files whose name matches a pattern' {
        Test-PathExcluded -RelativePath 'proj\app\mod.pyc' -Exclusions $ex | Should -BeTrue
        Test-PathExcluded -RelativePath '~$report.docx' -Exclusions $ex | Should -BeTrue
    }

    It 'keeps ordinary files, including ones that only contain an excluded word' {
        Test-PathExcluded -RelativePath 'proj\notes\node_modules.md' -Exclusions $ex | Should -BeFalse
        Test-PathExcluded -RelativePath 'proj\src\app.py' -Exclusions $ex | Should -BeFalse
    }

    It 'treats folder exclusions as folders only, like robocopy /XD' {
        Test-PathExcluded -RelativePath 'proj\.venv' -Exclusions $ex | Should -BeFalse
    }
}

Describe 'Test-MigrationConfig exclusion rules' {
    BeforeEach {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "w11m_cfg_$([guid]::NewGuid().ToString('N'))"
        Copy-Item -Path "$ProjectRoot/Config" -Destination (Join-Path $root 'Config') -Recurse
        $settingsPath = Join-Path $root 'Config/AppSettings.json'
    }
    AfterEach { Remove-Item -Path $root -Recurse -Force }

    It 'accepts the shipped configuration' {
        (Test-MigrationConfig -RootPath $root).Valid | Should -BeTrue
    }

    It 'rejects ExcludeDirectories that is not a list of strings' {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $s.ExcludeDirectories = 'node_modules'
        $s | ConvertTo-Json -Depth 5 | Set-Content $settingsPath
        $result = Test-MigrationConfig -RootPath $root
        $result.Valid | Should -BeFalse
        $result.Errors -join "`n" | Should -Match 'ExcludeDirectories'
    }

    It 'rejects an out-of-range thread count' {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $s.RobocopyThreadsByTarget.USB = 0
        $s | ConvertTo-Json -Depth 5 | Set-Content $settingsPath
        (Test-MigrationConfig -RootPath $root).Errors -join "`n" | Should -Match 'RobocopyThreadsByTarget.USB'
    }

    It 'rejects a profile whose Exclusions list is malformed' {
        $p = Join-Path $root 'Config/MigrationProfiles/Developer.json'
        $d = Get-Content $p -Raw | ConvertFrom-Json
        $d.Exclusions.Directories = @('', 'target')
        $d | ConvertTo-Json -Depth 5 | Set-Content $p
        (Test-MigrationConfig -RootPath $root).Errors -join "`n" | Should -Match 'Developer.json'
    }
}
