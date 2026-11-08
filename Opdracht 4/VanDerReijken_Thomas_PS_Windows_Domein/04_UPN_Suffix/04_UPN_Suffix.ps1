<#
.SYNOPSIS
    Deelopdracht 4 - Extra UPN-suffix toevoegen op forest-niveau en die als standaard
    gebruiken voor alle gebruikers binnen de bedrijfs-OU (OU=HQ), niet voor het hele domein.

.DESCRIPTION
    Uitvoeren op DC1 (WIN00-DC1) als Administrator (Enterprise Admin nodig voor Set-ADForest).

      1. Suffix toevoegen aan de forest (Set-ADForest -UPNSuffixes @{Add=...}).
      2. Het attribuut uPNSuffixes instellen op OU=HQ en alle onderliggende OU's.
         ADUC toont bij een nieuwe gebruiker in die OU dan deze suffix als standaard.
         Het attribuut werkt per OU (niet overervend), daarom zetten we het op elke sub-OU.
         Ook 03b_Gebruikers.ps1 leest dit attribuut uit voor nieuwe gebruikers.
      3. Alle bestaande gebruikers in OU=HQ (en sub-OU's) krijgen de nieuwe suffix.
         Gebruikers buiten OU=HQ (bv. Administrator in CN=Users) blijven ongewijzigd.

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$NieuwSuffix = 'company.be',
    [string]$BedrijfsOU  = 'OU=HQ,DC=HQ,DC=company,DC=com',
    [string]$LogMap      = 'C:\Opdracht'
)

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("04_UPN_Suffix_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    # --- 1. Suffix op forest-niveau ---------------------------------------
    $forest = Get-ADForest
    if ($forest.UPNSuffixes -contains $NieuwSuffix) {
        Write-Host "[OK]  UPN-suffix $NieuwSuffix bestaat al in de forest." -ForegroundColor Green
    }
    else {
        Set-ADForest -Identity $forest.Name -UPNSuffixes @{ Add = $NieuwSuffix }
        Write-Host "[DOE] UPN-suffix $NieuwSuffix toegevoegd aan forest $($forest.Name)." -ForegroundColor Yellow
    }
    Write-Host "Suffixen in de forest: $((Get-ADForest).UPNSuffixes -join ', ')"

    # --- 2. Standaard-suffix voor de bedrijfs-OU (en sub-OU's) -------------
    $ous = Get-ADOrganizationalUnit -SearchBase $BedrijfsOU -SearchScope Subtree -Filter * -Properties uPNSuffixes
    foreach ($ou in $ous) {
        if (@($ou.uPNSuffixes) -contains $NieuwSuffix -and @($ou.uPNSuffixes).Count -eq 1) {
            Write-Host "[OK]  $($ou.Name): uPNSuffixes al ingesteld." -ForegroundColor Green
        }
        else {
            Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -Replace @{ uPNSuffixes = $NieuwSuffix }
            Write-Host "[DOE] $($ou.Name): uPNSuffixes = $NieuwSuffix" -ForegroundColor Yellow
        }
    }

    # --- 3. Bestaande gebruikers aanpassen --------------------------------
    $gebruikers = Get-ADUser -SearchBase $BedrijfsOU -SearchScope Subtree -Filter * -Properties UserPrincipalName
    $overzicht  = @()

    foreach ($u in $gebruikers) {
        $prefix = if ($u.UserPrincipalName) { ($u.UserPrincipalName -split '@')[0] } else { $u.SamAccountName }
        $nieuw  = "$prefix@$NieuwSuffix"

        if ($u.UserPrincipalName -eq $nieuw) {
            $status = 'Al correct'
        }
        else {
            # Controle: UPN moet uniek zijn in de forest
            $conflict = Get-ADUser -Filter "UserPrincipalName -eq '$nieuw'" | Where-Object { $_.SID -ne $u.SID }
            if ($conflict) {
                $status = "Overgeslagen: $nieuw al in gebruik door $($conflict.SamAccountName)"
            }
            else {
                Set-ADUser -Identity $u -UserPrincipalName $nieuw
                $status = 'Aangepast'
            }
        }
        $overzicht += [pscustomobject]@{
            Gebruiker = $u.SamAccountName
            OudeUPN   = $u.UserPrincipalName
            NieuweUPN = $nieuw
            Status    = $status
        }
    }

    Write-Host "`nOverzicht gebruikers in $BedrijfsOU :" -ForegroundColor Cyan
    $overzicht | Format-Table -AutoSize

    Write-Host 'Controle - gebruikers BUITEN de bedrijfs-OU (moeten ongewijzigd zijn):' -ForegroundColor Cyan
    Get-ADUser -Filter * | Where-Object { $_.DistinguishedName -notlike "*,$BedrijfsOU" } |
        Select-Object SamAccountName, UserPrincipalName | Format-Table -AutoSize
}
catch {
    Write-Host "[FOUT] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
