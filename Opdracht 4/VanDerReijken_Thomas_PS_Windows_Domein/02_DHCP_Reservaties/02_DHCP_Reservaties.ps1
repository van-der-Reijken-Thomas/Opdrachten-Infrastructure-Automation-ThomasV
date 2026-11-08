<#
.SYNOPSIS
    Deelopdracht 2 - DHCP-reservaties aanmaken op DC1 vanuit een Excel-bestand
    en ze meteen repliceren naar de failover-partner (DC2).

.DESCRIPTION
    Uitvoeren op DC1 (WIN00-DC1) als Administrator.
    Input: 02_DHCP_Reservaties.xlsx, werkblad "Reservaties", met de kolommen
        ScopeId | IPAdres | MACAdres | Naam | Beschrijving

    Per rij:
      - MAC-adres wordt genormaliseerd naar het formaat 00-11-22-33-44-55
      - bestaat de reservatie al (zelfde IP + zelfde MAC) -> naam/beschrijving bijwerken
      - IP of MAC al gereserveerd voor iets anders -> overslaan met melding
      - anders -> reservatie aanmaken
    Daarna wordt per gewijzigde scope Invoke-DhcpServerv4FailoverReplication
    uitgevoerd. Reservaties worden namelijk NIET automatisch gerepliceerd.

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
    Vereist: module ImportExcel (wordt automatisch geinstalleerd als ze ontbreekt).
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ExcelPad    = '',   # leeg = Excel-bestand naast het script
    [string]$Werkblad    = 'Reservaties',
    [string]$DhcpServer  = 'win00-DC1.hq.company.com',
    [string]$LogMap      = 'C:\Opdracht'
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

function ConvertTo-DhcpMac {
    param([string]$Mac)
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($hex.Length -ne 12) { throw "Ongeldig MAC-adres: '$Mac'" }
    return (($hex -split '(..)' | Where-Object { $_ }) -join '-')
}

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("02_DHCP_Reservaties_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    if (-not $ExcelPad) { $ExcelPad = Join-Path $PSScriptRoot '02_DHCP_Reservaties.xlsx' }
    Initialize-ImportExcel
    Import-Module DhcpServer -ErrorAction Stop

    if (-not (Test-Path $ExcelPad)) { throw "Excel-bestand niet gevonden: $ExcelPad" }
    $rijen = @(Import-Excel -Path $ExcelPad -WorksheetName $Werkblad |
               Where-Object { $_.IPAdres -and $_.MACAdres })
    Write-Host "$($rijen.Count) reservaties ingelezen uit $ExcelPad" -ForegroundColor Cyan

    $resultaat      = @()
    $gewijzigdeScopes = @()

    foreach ($rij in $rijen) {
        $scope = [string]$rij.ScopeId
        $ip    = [string]$rij.IPAdres
        $naam  = [string]$rij.Naam
        $besch = [string]$rij.Beschrijving
        $status = ''

        try {
            $mac = ConvertTo-DhcpMac ([string]$rij.MACAdres)

            $bestaandIP  = Get-DhcpServerv4Reservation -ComputerName $DhcpServer -IPAddress $ip -ErrorAction SilentlyContinue
            $bestaandMAC = Get-DhcpServerv4Reservation -ComputerName $DhcpServer -ScopeId $scope -ErrorAction SilentlyContinue |
                           Where-Object { $_.ClientId -eq $mac }

            if ($bestaandIP -and $bestaandIP.ClientId -eq $mac) {
                if ($bestaandIP.Name -ne $naam -or $bestaandIP.Description -ne $besch) {
                    Set-DhcpServerv4Reservation -ComputerName $DhcpServer -IPAddress $ip -Name $naam -Description $besch
                    $status = 'Bijgewerkt'
                    $gewijzigdeScopes += $scope
                }
                else { $status = 'Bestond al' }
            }
            elseif ($bestaandIP) {
                $status = "Overgeslagen: IP al gereserveerd voor $($bestaandIP.ClientId)"
            }
            elseif ($bestaandMAC) {
                $status = "Overgeslagen: MAC al gereserveerd op $($bestaandMAC.IPAddress)"
            }
            else {
                $params = @{
                    ComputerName = $DhcpServer
                    ScopeId      = $scope
                    IPAddress    = $ip
                    ClientId     = $mac
                    Name         = $naam
                    Type         = 'Both'
                }
                if ($besch) { $params.Description = $besch }
                Add-DhcpServerv4Reservation @params -ErrorAction Stop
                $status = 'Aangemaakt'
                $gewijzigdeScopes += $scope
            }
        }
        catch {
            $status = "FOUT: $($_.Exception.Message)"
            $mac = [string]$rij.MACAdres
        }

        $resultaat += [pscustomobject]@{ IPAdres = $ip; MAC = $mac; Naam = $naam; Status = $status }
    }

    Write-Host "`nResultaat per rij:" -ForegroundColor Cyan
    $resultaat | Format-Table -AutoSize

    # --- Directe replicatie naar de failover-partner -----------------------
    $gewijzigdeScopes = $gewijzigdeScopes | Sort-Object -Unique
    if ($gewijzigdeScopes) {
        $relaties = @(Get-DhcpServerv4Failover -ComputerName $DhcpServer -ErrorAction SilentlyContinue)
        foreach ($s in $gewijzigdeScopes) {
            $relatie = $relaties | Where-Object { $_.ScopeId.IPAddressToString -contains $s }
            if (-not $relatie) {
                Write-Host "Scope $s zit niet in een failover-relatie -> geen replicatie mogelijk (voer eerst deel 1 uit)." -ForegroundColor Red
                continue
            }
            Invoke-DhcpServerv4FailoverReplication -ComputerName $DhcpServer -ScopeId $s -Force | Out-Null
            Write-Host "Scope $s gerepliceerd naar $($relatie.PartnerServer)" -ForegroundColor Green

            # Controle: reservaties op beide servers naast elkaar
            Write-Host "`nReservaties in scope $s op beide servers:" -ForegroundColor Cyan
            @($DhcpServer, $relatie.PartnerServer) | ForEach-Object {
                $srv = $_
                Get-DhcpServerv4Reservation -ComputerName $srv -ScopeId $s |
                    Select-Object @{n='Server';e={$srv}}, IPAddress, ClientId, Name, Description
            } | Sort-Object IPAddress, Server | Format-Table -AutoSize
        }
    }
    else {
        Write-Host 'Geen wijzigingen, replicatie niet nodig.' -ForegroundColor Green
    }
}
catch {
    Write-Host "[FOUT] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
