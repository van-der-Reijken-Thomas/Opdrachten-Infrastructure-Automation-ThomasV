<#
.SYNOPSIS
    Deelopdracht 5 - Fictieve OU-structuur aanmaken op basis van een organigram.

.DESCRIPTION
    Uitvoeren op DC1 (WIN00-DC1) als Administrator.
    Input: 05_OU_Structuur.xlsx, werkblad "OUs", met de kolommen
        Pad | Beschrijving
    Pad is de plaats in het organigram, niveaus gescheiden door "/", bv.
        EnYoi Holding/EnYoi ICT Services/Divisie Commercieel/Verkoop

    Het script sorteert de rijen op diepte (eerst bovenste niveau) zodat een
    bovenliggende OU altijd bestaat voor de onderliggende wordt aangemaakt.
    Bestaande OU's worden overgeslagen. Op het einde wordt de boom getoond.

    Bron organigram: AFAS Help Center - voorbeeldorganigram "EnYoi Holding"
    https://help.afas.nl/help/NL/SE/Hrm_Config_OrgCrt.htm

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
    Vereist: module ActiveDirectory, module ImportExcel (wordt automatisch geinstalleerd).
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ExcelPad  = '',   # leeg = Excel-bestand naast het script
    [string]$Werkblad  = 'OUs',
    [string]$BasisDN   = '',            # leeg = root van het domein
    [bool]$Beveiligen  = $true,         # ProtectedFromAccidentalDeletion
    [string]$LogMap    = 'C:\Opdracht'
)

function Initialize-ImportExcel {
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Host 'Module ImportExcel niet gevonden -> installeren vanaf de PowerShell Gallery...' -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ImportExcel -ErrorAction Stop
}

function ConvertTo-OuDN {
    # "A/B/C" -> "OU=C,OU=B,OU=A,<basis>"
    param([string[]]$Delen, [string]$Basis)
    $ouDelen = @($Delen)
    [array]::Reverse($ouDelen)
    return ((@($ouDelen | ForEach-Object { "OU=$_" }) + $Basis) -join ',')
}

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("05_OU_Structuur_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    if (-not $ExcelPad) { $ExcelPad = Join-Path $PSScriptRoot '05_OU_Structuur.xlsx' }
    Import-Module ActiveDirectory -ErrorAction Stop
    Initialize-ImportExcel

    if (-not $BasisDN) { $BasisDN = (Get-ADDomain).DistinguishedName }
    if (-not (Test-Path $ExcelPad)) { throw "Excel-bestand niet gevonden: $ExcelPad" }

    $rijen = @(Import-Excel -Path $ExcelPad -WorksheetName $Werkblad | Where-Object { $_.Pad } |
             ForEach-Object {
                 $delen = @(([string]$_.Pad).Split('/') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                 [pscustomobject]@{ Delen = $delen; Diepte = $delen.Count; Beschrijving = [string]$_.Beschrijving }
             } | Sort-Object Diepte)

    Write-Host "$($rijen.Count) OU's ingelezen uit $ExcelPad" -ForegroundColor Cyan
    $teller = @{ Aangemaakt = 0; Bestond = 0; Fout = 0 }

    foreach ($rij in $rijen) {
        $naam     = $rij.Delen[-1]
        $parentDN = if ($rij.Diepte -gt 1) { ConvertTo-OuDN -Delen $rij.Delen[0..($rij.Diepte - 2)] -Basis $BasisDN } else { $BasisDN }
        $dn       = "OU=$naam,$parentDN"

        if ([adsi]::Exists("LDAP://$dn")) {
            Write-Host "[OK]  bestaat al : $dn" -ForegroundColor Green
            $teller.Bestond++
            continue
        }
        try {
            $params = @{
                Name                            = $naam
                Path                            = $parentDN
                ProtectedFromAccidentalDeletion = $Beveiligen
            }
            if ($rij.Beschrijving) { $params.Description = $rij.Beschrijving }
            New-ADOrganizationalUnit @params -ErrorAction Stop
            Write-Host "[DOE] aangemaakt : $dn" -ForegroundColor Yellow
            $teller.Aangemaakt++
        }
        catch {
            Write-Host "[FOUT] $dn : $($_.Exception.Message)" -ForegroundColor Red
            $teller.Fout++
        }
    }

    Write-Host ("`nAangemaakt: {0}  Bestond al: {1}  Fouten: {2}" -f $teller.Aangemaakt, $teller.Bestond, $teller.Fout) -ForegroundColor Cyan

    # --- Boomweergave van de structuur ------------------------------------
    $topNamen = @($rijen | Where-Object { $_.Diepte -eq 1 } | ForEach-Object { $_.Delen[0] })
    foreach ($top in $topNamen) {
        $topDN = "OU=$top,$BasisDN"
        Write-Host "`nOU-structuur onder $topDN :" -ForegroundColor Cyan
        Get-ADOrganizationalUnit -SearchBase $topDN -SearchScope Subtree -Filter * -Properties CanonicalName, Description |
            Sort-Object CanonicalName |
            ForEach-Object {
                $niveau = ($_.CanonicalName -split '/').Count - 2
                $tekst  = ('    ' * $niveau) + '|-- ' + $_.Name
                if ($_.Description) { $tekst = $tekst.PadRight(55) + "($($_.Description))" }
                Write-Host $tekst
            }
    }
}
catch {
    Write-Host "[FOUT] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
