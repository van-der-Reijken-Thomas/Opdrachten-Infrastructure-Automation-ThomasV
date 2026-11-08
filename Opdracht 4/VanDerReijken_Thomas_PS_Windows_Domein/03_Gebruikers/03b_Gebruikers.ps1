<#
.SYNOPSIS
    Deelopdracht 3b - Nieuwe gebruikers aanmaken op DC1 vanuit een Excel-bestand.

.DESCRIPTION
    Uitvoeren op DC1 (WIN00-DC1) als Administrator, NA 03a_HomeShare_MS.ps1 op MS.
    Input: 03_Gebruikers.xlsx, werkblad "Gebruikers", met de kolommen
        Voornaam | Achternaam | Gebruikersnaam | Afdeling | Groep | Functie

    Per rij:
      - OU  = OU=<Afdeling>,OU=HQ,...  (wordt aangemaakt als ze niet bestaat)
      - Groep = globale beveiligingsgroep in OU=!Groups,OU=HQ (aangemaakt indien nodig)
      - UPN-suffix: als de OU een uPNSuffixes-attribuut heeft (zie deel 4) wordt dat gebruikt,
        anders de domeinnaam.
      - Gebruiker aanmaken (of verplaatsen naar de juiste OU als hij al bestaat)
      - Lid maken van de groep
      - Homemap \\WIN00-MS\Home$\<gebruikersnaam> aanmaken, H: koppelen in het profiel
        en de gebruiker Full Control geven op zijn eigen map.

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
    Vereist: module ActiveDirectory, module ImportExcel (wordt automatisch geinstalleerd).
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ExcelPad      = '',   # leeg = Excel-bestand naast het script
    [string]$Werkblad      = 'Gebruikers',
    [string]$BedrijfsOU    = 'OU=HQ,DC=HQ,DC=company,DC=com',
    [string]$GroepenOU     = 'OU=!Groups,OU=HQ,DC=HQ,DC=company,DC=com',
    [string]$HomeShare     = '\\WIN00-MS\Home$',
    [string]$HomeDrive     = 'H:',
    [string]$Bedrijf       = 'Company',
    [securestring]$StartWachtwoord,
    [string]$LogMap        = 'C:\Opdracht'
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

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("03b_Gebruikers_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    if (-not $ExcelPad) { $ExcelPad = Join-Path $PSScriptRoot '03_Gebruikers.xlsx' }
    Import-Module ActiveDirectory -ErrorAction Stop
    Initialize-ImportExcel

    if (-not (Test-Path $ExcelPad))  { throw "Excel-bestand niet gevonden: $ExcelPad" }
    if (-not (Test-Path $HomeShare)) { throw "Home share $HomeShare niet bereikbaar. Voer eerst 03a_HomeShare_MS.ps1 uit op MS." }

    if (-not $StartWachtwoord) {
        $StartWachtwoord = Read-Host -AsSecureString 'Startwachtwoord voor de nieuwe gebruikers (moet bij eerste aanmelding gewijzigd worden)'
    }

    $domein = (Get-ADDomain).DNSRoot
    $rijen  = @(Import-Excel -Path $ExcelPad -WorksheetName $Werkblad | Where-Object { $_.Gebruikersnaam })
    Write-Host "$($rijen.Count) gebruikers ingelezen uit $ExcelPad" -ForegroundColor Cyan

    $resultaat = @()

    foreach ($rij in $rijen) {
        $voornaam = ([string]$rij.Voornaam).Trim()
        $achternm = ([string]$rij.Achternaam).Trim()
        $sam      = ([string]$rij.Gebruikersnaam).Trim().ToLower()
        $afdeling = ([string]$rij.Afdeling).Trim()
        $groep    = ([string]$rij.Groep).Trim()
        $functie  = ([string]$rij.Functie).Trim()
        $volNaam  = "$voornaam $achternm"
        $acties   = @()

        try {
            # --- OU -------------------------------------------------------
            $ouDN = "OU=$afdeling,$BedrijfsOU"
            $ou   = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -Properties uPNSuffixes
            if (-not $ou) {
                New-ADOrganizationalUnit -Name $afdeling -Path $BedrijfsOU -ProtectedFromAccidentalDeletion $true
                $ou = Get-ADOrganizationalUnit -Identity $ouDN -Properties uPNSuffixes
                $acties += 'OU aangemaakt'
            }
            $suffix = if ($ou.uPNSuffixes) { @($ou.uPNSuffixes)[0] } else { $domein }

            # --- Groep ----------------------------------------------------
            $grp = Get-ADGroup -Filter "Name -eq '$groep'"
            if (-not $grp) {
                $grp = New-ADGroup -Name $groep -SamAccountName $groep -GroupScope Global `
                        -GroupCategory Security -Path $GroepenOU -Description "Afdeling $afdeling" -PassThru
                $acties += 'groep aangemaakt'
            }

            # --- Gebruiker ------------------------------------------------
            $homeDir = "$HomeShare\$sam"
            $user = Get-ADUser -Filter "SamAccountName -eq '$sam'"
            if (-not $user) {
                $nieuw = @{
                    Name                  = $volNaam
                    GivenName             = $voornaam
                    Surname               = $achternm
                    DisplayName           = $volNaam
                    SamAccountName        = $sam
                    UserPrincipalName     = "$sam@$suffix"
                    Title                 = $functie
                    Department            = $afdeling
                    Company               = $Bedrijf
                    Path                  = $ouDN
                    AccountPassword       = $StartWachtwoord
                    ChangePasswordAtLogon = $true
                    Enabled               = $true
                    HomeDrive             = $HomeDrive
                    HomeDirectory         = $homeDir
                }
                New-ADUser @nieuw
                $acties += 'gebruiker aangemaakt'
            }
            else {
                $huidigeOU = ($user.DistinguishedName -split ',', 2)[1]
                if ($huidigeOU -ne $ouDN) {
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $ouDN
                    $acties += 'verplaatst naar juiste OU'
                }
                Set-ADUser -Identity $sam -HomeDrive $HomeDrive -HomeDirectory $homeDir -Title $functie -Department $afdeling
                $acties += 'bestond al, bijgewerkt'
            }
            $user = Get-ADUser -Identity $sam

            # --- Groepslidmaatschap --------------------------------------
            $isLid = Get-ADGroupMember -Identity $grp | Where-Object { $_.SID -eq $user.SID }
            if (-not $isLid) {
                Add-ADGroupMember -Identity $grp -Members $user
                $acties += "lid van $groep"
            }

            # --- Homemap op MS -------------------------------------------
            if (-not (Test-Path $homeDir)) {
                New-Item -ItemType Directory -Path $homeDir | Out-Null
                $acties += 'homemap aangemaakt'
            }
            # Recht toekennen via SID: werkt ook als MS de nieuwe naam nog niet kan opzoeken
            $acl   = Get-Acl -Path $homeDir
            $regel = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $user.SID, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($regel)
            Set-Acl -Path $homeDir -AclObject $acl

            $resultaat += [pscustomobject]@{
                Gebruiker = $sam; UPN = "$sam@$suffix"; OU = $afdeling; Groep = $groep; Status = ($acties -join ', ')
            }
        }
        catch {
            $resultaat += [pscustomobject]@{
                Gebruiker = $sam; UPN = ''; OU = $afdeling; Groep = $groep; Status = "FOUT: $($_.Exception.Message)"
            }
        }
    }

    Write-Host "`nResultaat:" -ForegroundColor Cyan
    $resultaat | Format-Table -AutoSize -Wrap

    Write-Host 'Controle - gebruikers in de bedrijfs-OU:' -ForegroundColor Cyan
    Get-ADUser -SearchBase $BedrijfsOU -Filter * -Properties HomeDirectory, HomeDrive, MemberOf |
        Select-Object SamAccountName, UserPrincipalName,
            @{n='OU';e={($_.DistinguishedName -split ',')[1] -replace 'OU='}},
            HomeDrive, HomeDirectory,
            @{n='Groepen';e={($_.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join ', '}} |
        Format-Table -AutoSize
}
catch {
    Write-Host "[FOUT] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
