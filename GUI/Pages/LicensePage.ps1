<#
========================================================================================================
    Title:          Win11Migrator - License Agreement Page
    Filename:       LicensePage.ps1
    Description:    Displays the MIT license agreement and requires user acceptance to proceed.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-LicensePage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $txtLicense = $Page.FindName('txtLicense')
    $chkAcceptLicense = $Page.FindName('chkAcceptLicense')

    # Disable Next until license is accepted
    $State.BtnNext.IsEnabled = $false
    $State.BtnNext.Visibility = 'Visible'

    # Load license text
    $licensePath = Join-Path $State.MigratorRoot "LICENSE"
    if (Test-Path $licensePath) {
        $txtLicense.Text = Get-Content $licensePath -Raw
    } else {
        $txtLicense.Text = "MIT License`r`n`r`nCopyright (c) 2026 AuthorityGate`r`nCopyright (c) 2026 Aurumdev952`r`n`r`nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the `"Software`"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:`r`n`r`nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.`r`n`r`nTHE SOFTWARE IS PROVIDED `"AS IS`", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."
    }

    # Toggle Next button based on checkbox
    $chkAcceptLicense.Add_Checked({
        $State.BtnNext.IsEnabled = $true
    }.GetNewClosure())

    $chkAcceptLicense.Add_Unchecked({
        $State.BtnNext.IsEnabled = $false
    }.GetNewClosure())
}
