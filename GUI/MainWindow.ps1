<#
========================================================================================================
    Title:          Win11Migrator - WPF Main Window Logic
    Filename:       MainWindow.ps1
    Description:    Main window logic: loads XAML, manages wizard navigation, and orchestrates background runspaces.
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
    Main window logic: loads XAML, manages wizard navigation, and orchestrates background runspaces.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --- Shared XAML loader that handles relative resource paths ---
function Import-Xaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XamlPath
    )

    if (-not (Test-Path $XamlPath)) {
        throw "XAML file not found: $XamlPath"
    }

    $xamlContent = Get-Content $XamlPath -Raw

    # Remove x:Class attributes (not used in PowerShell)
    $xamlContent = $xamlContent -replace 'x:Class="[^"]*"\s*', ''

    # Set up parser context with BaseUri so relative Source paths resolve correctly
    $parserContext = [System.Windows.Markup.ParserContext]::new()
    $absolutePath = (Resolve-Path $XamlPath).Path -replace '\\', '/'
    $parserContext.BaseUri = [Uri]::new("file:///$absolutePath")

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($xamlContent)
    $stream = [System.IO.MemoryStream]::new($bytes)

    try {
        $element = [System.Windows.Markup.XamlReader]::Load($stream, $parserContext)
        return $element
    } finally {
        $stream.Dispose()
    }
}

function Show-MainWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$MigratorRoot
    )

    # --- Load XAML ---
    $xamlPath = Join-Path $MigratorRoot "GUI\MainWindow.xaml"
    $window = Import-Xaml -XamlPath $xamlPath

    # --- Find controls ---
    $mainFrame = $window.FindName('MainFrame')
    $btnCancel = $window.FindName('btnCancel')
    $btnBack = $window.FindName('btnBack')
    $btnNext = $window.FindName('btnNext')
    $txtStepIndicator = $window.FindName('txtStepIndicator')

    # --- Shared state (synchronized for thread-safe access from background runspaces) ---
    $state = [hashtable]::Synchronized(@{
        Mode              = $null        # 'Export', 'Import' or 'Receive'
        Config            = $Config
        MigratorRoot      = $MigratorRoot
        Window            = $window
        MainFrame         = $mainFrame
        CurrentPageIndex  = 0
        ExportPages       = @('WelcomePage', 'LicensePage', 'ScanProgressPage', 'AppSelectionPage', 'DataSelectionPage', 'StorageSelectionPage', 'ExportProgressPage', 'CompletionPage')
        ImportPages       = @('WelcomePage', 'LicensePage', 'ImportSourcePage', 'ImportProgressPage', 'CompletionPage')
        ReceivePages      = @('WelcomePage', 'LicensePage', 'ReceivePage', 'ImportProgressPage', 'CompletionPage')
        Pages             = @('WelcomePage')  # Start with just welcome
        Apps              = @()
        UserData          = @()
        BrowserProfiles   = @()
        SystemSettings    = @()
        AppProfiles       = @()
        Manifest          = $null
        PackagePath       = $null
        StorageTarget     = $null
        RunspacePool      = $null
        ActiveJob         = $null
    })

    # --- Page loader ---
    $loadPage = {
        param([string]$PageName, [hashtable]$State)

        $pagesDir = Join-Path $State.MigratorRoot "GUI\Pages"
        $xamlFile = Join-Path $pagesDir "$PageName.xaml"
        $psFile = Join-Path $pagesDir "$PageName.ps1"

        if (-not (Test-Path $xamlFile)) {
            Write-MigrationLog -Message "Page XAML not found: $xamlFile" -Level Error
            return $null
        }

        try {
            $page = Import-Xaml -XamlPath $xamlFile
        } catch {
            Write-MigrationLog -Message "Failed to load page $PageName : $($_.Exception.Message)" -Level Error
            return $null
        }

        # Load page logic
        if (Test-Path $psFile) {
            . $psFile
            $initFunc = "Initialize-$PageName"
            if (Get-Command $initFunc -ErrorAction SilentlyContinue) {
                try {
                    & $initFunc -Page $page -State $State
                } catch {
                    Write-MigrationLog -Message "Failed to initialize $PageName : $($_.Exception.Message)" -Level Error
                }
            }
        }

        return $page
    }

    # --- Navigation functions ---
    $navigateTo = {
        param([int]$PageIndex, [hashtable]$State)

        if ($PageIndex -lt 0 -or $PageIndex -ge $State.Pages.Count) { return }

        # Clear stale OnTick handler from previous page
        $State.OnTick = $null

        $State.CurrentPageIndex = $PageIndex
        $pageName = $State.Pages[$PageIndex]

        # Use cached page if available; only reload fresh pages
        if (-not $State.PageCache) { $State.PageCache = @{} }
        if ($State.PageCache.ContainsKey($pageName)) {
            $page = $State.PageCache[$pageName]
        } else {
            $page = & $loadPage $pageName $State
            if ($page) { $State.PageCache[$pageName] = $page }
        }

        if ($page) {
            $State.MainFrame.Navigate($page)
        }

        # Update step indicator
        $txtStepIndicator.Text = "Step $($PageIndex + 1) of $($State.Pages.Count)"

        # Update button states (re-enable Back — progress pages will disable it in their init)
        $btnBack.Visibility = if ($PageIndex -eq 0) { 'Collapsed' } else { 'Visible' }
        $btnBack.IsEnabled = $true

        $lastPage = $State.Pages.Count - 1
        if ($PageIndex -eq $lastPage) {
            $btnNext.Content = "Finish"
        } elseif ($PageIndex -eq 0) {
            $btnNext.Content = "Next"
            $btnNext.Visibility = 'Collapsed'  # Welcome page uses its own buttons
        } else {
            $btnNext.Content = "Next"
            $btnNext.Visibility = 'Visible'
        }
    }

    # --- Button handlers ---
    $btnCancel.Add_Click({
        $result = [System.Windows.MessageBox]::Show(
            "Are you sure you want to cancel the migration?",
            "Cancel Migration",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            $window.Close()
        }
    }.GetNewClosure())

    $btnBack.Add_Click({
        $newIndex = $state.CurrentPageIndex - 1
        if ($newIndex -ge 0) {
            & $navigateTo $newIndex $state
        }
    }.GetNewClosure())

    $btnNext.Add_Click({
        $newIndex = $state.CurrentPageIndex + 1
        if ($newIndex -lt $state.Pages.Count) {
            & $navigateTo $newIndex $state
        } elseif ($state.CurrentPageIndex -eq ($state.Pages.Count - 1)) {
            # Finish button - close
            $window.Close()
        }
    }.GetNewClosure())

    # Expose navigation to pages via state
    $state['NavigateTo'] = $navigateTo
    $state['LoadPage'] = $loadPage
    $state['BtnNext'] = $btnNext
    $state['BtnBack'] = $btnBack
    $state['TxtStepIndicator'] = $txtStepIndicator

    # --- Set mode callback (called from WelcomePage) ---
    $state['SetMode'] = {
        param([string]$Mode, [hashtable]$State)
        $State.Mode = $Mode
        $State.Pages = switch ($Mode) {
            'Export'  { $State.ExportPages }
            'Receive' { $State.ReceivePages }
            default   { $State.ImportPages }
        }
        # Navigate to page 1 (after welcome)
        $State.BtnNext.Visibility = 'Visible'
        & $State.NavigateTo 1 $State
    }

    # Dynamic page insertion/removal for NetworkDirect mode
    $state['InsertNetworkPage'] = {
        param([hashtable]$State)
        # Insert NetworkTargetPage after StorageSelectionPage if not already present
        if ($State.Pages -notcontains 'NetworkTargetPage') {
            $storageIdx = [Array]::IndexOf($State.Pages, 'StorageSelectionPage')
            if ($storageIdx -ge 0) {
                $newPages = @()
                for ($i = 0; $i -lt $State.Pages.Count; $i++) {
                    $newPages += $State.Pages[$i]
                    if ($i -eq $storageIdx) {
                        $newPages += 'NetworkTargetPage'
                    }
                }
                $State.Pages = $newPages
                $State.ExportPages = $newPages
            }
        }
    }

    $state['RemoveNetworkPage'] = {
        param([hashtable]$State)
        # Remove NetworkTargetPage if present (user switched away from NetworkDirect)
        if ($State.Pages -contains 'NetworkTargetPage') {
            $State.Pages = @($State.Pages | Where-Object { $_ -ne 'NetworkTargetPage' })
            $State.ExportPages = $State.Pages
            # Clear cached page so it reinitializes if re-inserted
            if ($State.PageCache -and $State.PageCache.ContainsKey('NetworkTargetPage')) {
                $State.PageCache.Remove('NetworkTargetPage')
            }
        }
    }

    # --- Start background dispatch timer for UI updates ---
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        # Process log queue for any active log viewer
        # Pages can register their own tick handlers via $state.OnTick
        if ($state.OnTick) {
            try { & $state.OnTick $state } catch {
                Write-Host "[TICK ERROR] $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "  at $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
            }
        }
    }.GetNewClosure())
    $timer.Start()
    $state['Timer'] = $timer

    # --- Navigate to Welcome ---
    & $navigateTo 0 $state

    # --- Show window ---
    $window.ShowDialog() | Out-Null

    # --- Cleanup ---
    $timer.Stop()
    $state.OnTick = $null
    # Stop and dispose any active background job (export/import runspace)
    if ($state.ActiveJob) {
        try {
            if ($state.ActiveJob.PowerShell) {
                $state.ActiveJob.PowerShell.Stop()
                $state.ActiveJob.PowerShell.Dispose()
            }
            if ($state.ActiveJob.Runspace) {
                $state.ActiveJob.Runspace.Close()
                $state.ActiveJob.Runspace.Dispose()
            }
        } catch {}
        $state.ActiveJob = $null
    }
    # A receive session opens a share, an account and firewall rules; never leave them behind
    if ($state.ReceiveSession) {
        try { Stop-ReceiveSession -Session $state.ReceiveSession } catch {}
        $state.ReceiveSession = $null
    }
    if ($state.AppWorker) {
        try { $state.AppWorker.PowerShell.Stop(); $state.AppWorker.PowerShell.Dispose(); $state.AppWorker.Runspace.Dispose() } catch {}
        $state.AppWorker = $null
    }
    # Stop and dispose any active scan runspaces
    if ($state.ScanCtx) {
        foreach ($jobKey in @('AppJob', 'LocalJob', 'ResolveJob', 'ChocoJob')) {
            $scanJob = $state.ScanCtx[$jobKey]
            if ($scanJob) {
                try {
                    if ($scanJob.PowerShell) { $scanJob.PowerShell.Stop(); $scanJob.PowerShell.Dispose() }
                    if ($scanJob.Runspace) { $scanJob.Runspace.Close(); $scanJob.Runspace.Dispose() }
                } catch {}
                $state.ScanCtx[$jobKey] = $null
            }
        }
    }
    if ($state.RunspacePool) {
        $state.RunspacePool.Close()
        $state.RunspacePool.Dispose()
    }
}

# --- Helper: Run script in background runspace with UI callback ---
function Start-BackgroundOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [System.Windows.Threading.Dispatcher]$Dispatcher,

        [scriptblock]$OnProgress,
        [scriptblock]$OnComplete,
        [scriptblock]$OnError,
        [hashtable]$Parameters
    )

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()

    # Pass parameters into runspace
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            $runspace.SessionStateProxy.SetVariable($key, $Parameters[$key])
        }
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript($ScriptBlock) | Out-Null

    $handle = $ps.BeginInvoke()

    # Return handle for polling
    return @{
        PowerShell = $ps
        Handle     = $handle
        Runspace   = $runspace
        Dispatcher = $Dispatcher
        OnComplete = $OnComplete
        OnError    = $OnError
    }
}

function Complete-BackgroundOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job
    )

    if ($Job.Handle.IsCompleted) {
        try {
            $result = $Job.PowerShell.EndInvoke($Job.Handle)
            if ($Job.OnComplete) {
                if ($Job.Dispatcher) {
                    $Job.Dispatcher.Invoke([Action[object]]{ param($r) & $Job.OnComplete $r }, $result)
                } else {
                    & $Job.OnComplete $result
                }
            }
        } catch {
            if ($Job.OnError) {
                if ($Job.Dispatcher) {
                    $Job.Dispatcher.Invoke([Action[string]]{ param($e) & $Job.OnError $e }, $_.Exception.Message)
                } else {
                    & $Job.OnError $_.Exception.Message
                }
            }
        } finally {
            try {
                $Job.PowerShell.Dispose()
                $Job.Runspace.Close()
                $Job.Runspace.Dispose()
            } catch {}
        }
        return $true
    }
    return $false
}
