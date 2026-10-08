<#
========================================================================================================
    Title:          Win11Migrator - Welcome Page
    Filename:       WelcomePage.ps1
    Description:    Welcome page logic with Export/Import mode selection cards.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-WelcomePage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $cardExport = $Page.FindName('cardExport')
    $cardImport = $Page.FindName('cardImport')
    $cardReceive = $Page.FindName('cardReceive')

    # Hide footer nav on welcome page
    $State.BtnNext.Visibility = 'Collapsed'
    $State.BtnBack.Visibility = 'Collapsed'

    # Hover effects
    $highlightCard = {
        param($card, $color)
        $card.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    }
    $resetCard = {
        param($card)
        $card.BorderBrush = $card.FindResource('BorderBrush')
    }

    $cardExport.Add_MouseEnter({ $this.BorderBrush = $this.FindResource('PrimaryBrush') })
    $cardExport.Add_MouseLeave({ $this.BorderBrush = $this.FindResource('BorderBrush') })
    $cardImport.Add_MouseEnter({ $this.BorderBrush = $this.FindResource('AccentBrush') })
    $cardImport.Add_MouseLeave({ $this.BorderBrush = $this.FindResource('BorderBrush') })
    $cardReceive.Add_MouseEnter({ $this.BorderBrush = $this.FindResource('AccentBrush') })
    $cardReceive.Add_MouseLeave({ $this.BorderBrush = $this.FindResource('BorderBrush') })

    # Click handlers
    $cardExport.Add_MouseLeftButtonUp({
        & $State.SetMode 'Export' $State
    }.GetNewClosure())

    $cardImport.Add_MouseLeftButtonUp({
        & $State.SetMode 'Import' $State
    }.GetNewClosure())

    $cardReceive.Add_MouseLeftButtonUp({
        & $State.SetMode 'Receive' $State
    }.GetNewClosure())
}
