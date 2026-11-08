<#
.SYNOPSIS
    Deelopdracht 1 - DHCP redundantie: DC2 configureren als failover-partner van DC1.

.DESCRIPTION
    Uitvoeren op DC2 (WIN00-DC2) in een PowerShell-venster als Administrator.
    Het script is idempotent: elke stap controleert eerst de huidige toestand en
    voert alleen uit wat nog ontbreekt. Je kan het dus meerdere keren draaien.

    Stappen:
      1. Controle of de DHCP-rol + beheertools (RSAT-DHCP) geinstalleerd zijn, zo niet installeren.
      2. DHCP-beveiligingsgroepen aanmaken en de service herstarten.
      3. DC2 autoriseren in Active Directory (en foute autorisaties van DC2 opkuisen).
      4. Waarschuwing "Complete DHCP configuration" in Server Manager wegwerken.
      5. Serveropties van DC1 overnemen op DC2, met de DNS-servers (optie 6) in omgekeerde volgorde.
      6. Failover-relatie (load balance) opzetten of aanvullen met alle scopes van DC1.
      7. Replicatie forceren en het resultaat tonen.

.NOTES
    Auteur : Thomas van der Reijken
    Datum  : november 2026
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$PrimaryServer      = 'win00-DC1.hq.company.com',   # bestaande DHCP-server
    [string]$PartnerServer      = 'win00-DC2.hq.company.com',   # deze server (DC2)
    [string]$PartnerIP          = '192.168.1.3',
    [string]$FailoverName       = 'DC1-DC2-Failover',
    [ValidateRange(0,100)]
    [int]$LoadBalancePercent    = 50,
    [securestring]$SharedSecret,
    [string]$LogMap             = 'C:\Opdracht'
)

# ---------------------------------------------------------------------------
# Hulpfuncties
# ---------------------------------------------------------------------------
function Write-Stap {
    param([string]$Tekst)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host $Tekst -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Ok   { param([string]$Tekst) Write-Host "  [OK]   $Tekst" -ForegroundColor Green }
function Write-Actie{ param([string]$Tekst) Write-Host "  [DOE]  $Tekst" -ForegroundColor Yellow }
function Write-Fout { param([string]$Tekst) Write-Host "  [FOUT] $Tekst" -ForegroundColor Red }

New-Item -ItemType Directory -Path $LogMap -Force | Out-Null
Start-Transcript -Path (Join-Path $LogMap ("01_DHCP_Redundantie_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))) | Out-Null

try {
    # -----------------------------------------------------------------------
    Write-Stap '1. Controle DHCP-rol en beheertools op DC2'
    # -----------------------------------------------------------------------
    $features = Get-WindowsFeature -Name DHCP, RSAT-DHCP
    $features | Select-Object Name, InstallState | Format-Table -AutoSize

    $ontbrekend = $features | Where-Object { -not $_.Installed }
    if ($ontbrekend) {
        Write-Actie "Niet geinstalleerd: $($ontbrekend.Name -join ', ') -> installeren"
        $res = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if (-not $res.Success) { throw 'Installatie van de DHCP-rol is mislukt.' }
        if ($res.RestartNeeded -eq 'Yes') { Write-Actie 'Windows vraagt een herstart. Herstart DC2 en draai het script opnieuw.' }
        Write-Ok 'DHCP-rol en beheertools geinstalleerd.'
    }
    else {
        Write-Ok 'DHCP-rol en RSAT-DHCP waren al geinstalleerd.'
    }
    Import-Module DhcpServer -ErrorAction Stop

    # -----------------------------------------------------------------------
    Write-Stap '2. DHCP-beveiligingsgroepen (DHCP Users / DHCP Administrators)'
    # -----------------------------------------------------------------------
    try {
        Add-DhcpServerSecurityGroup -ComputerName $PartnerServer -ErrorAction Stop
        Write-Ok 'Beveiligingsgroepen aangemaakt of al aanwezig.'
    }
    catch {
        Write-Ok "Beveiligingsgroepen bestaan al ($($_.Exception.Message))."
    }
    Restart-Service -Name DHCPServer -Force
    # Wachten tot de DHCP-service echt antwoordt (anders faalt de failover-stap)
    $klaar = $false
    for ($i = 0; $i -lt 15 -and -not $klaar; $i++) {
        Start-Sleep -Seconds 2
        try { Get-DhcpServerSetting -ComputerName $PartnerServer -ErrorAction Stop | Out-Null; $klaar = $true } catch { }
    }
    Start-Sleep -Seconds 5
    Write-Ok 'DHCP-service herstart zodat de groepen actief worden.'

    # -----------------------------------------------------------------------
    Write-Stap '3. Autorisatie van DC2 in Active Directory'
    # -----------------------------------------------------------------------
    $autorisaties = @(Get-DhcpServerInDC)

    # Foute entries voor DC2 (zelfde naam, verkeerd IP) opruimen
    $fout = $autorisaties | Where-Object {
        $_.DnsName -eq $PartnerServer -and $_.IPAddress.IPAddressToString -ne $PartnerIP
    }
    foreach ($f in $fout) {
        Write-Actie "Foute autorisatie verwijderen: $($f.DnsName) / $($f.IPAddress)"
        Remove-DhcpServerInDC -DnsName $f.DnsName -IPAddress $f.IPAddress
    }

    $ok = $autorisaties | Where-Object { $_.IPAddress.IPAddressToString -eq $PartnerIP }
    if ($ok) {
        Write-Ok "DC2 ($PartnerIP) is al geautoriseerd in AD."
    }
    else {
        Write-Actie "DC2 autoriseren: $PartnerServer / $PartnerIP"
        Add-DhcpServerInDC -DnsName $PartnerServer -IPAddress $PartnerIP
        Write-Ok 'DC2 geautoriseerd.'
    }
    Get-DhcpServerInDC | Format-Table -AutoSize

    # -----------------------------------------------------------------------
    Write-Stap '4. Waarschuwing in Server Manager wegwerken'
    # -----------------------------------------------------------------------
    $regPad = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
    $huidig = (Get-ItemProperty -Path $regPad -Name ConfigurationState -ErrorAction SilentlyContinue).ConfigurationState
    if ($huidig -eq 2) {
        Write-Ok 'ConfigurationState staat al op 2 (configuratie afgewerkt).'
    }
    else {
        Write-Actie "ConfigurationState is '$huidig' -> op 2 zetten"
        if (-not (Test-Path $regPad)) { New-Item -Path $regPad -Force | Out-Null }
        Set-ItemProperty -Path $regPad -Name ConfigurationState -Value 2
        Write-Ok 'Waarschuwing verdwijnt na het vernieuwen van Server Manager.'
    }

    # -----------------------------------------------------------------------
    Write-Stap '5. Serveropties overnemen van DC1 (DNS-servers omgekeerd)'
    # -----------------------------------------------------------------------
    # Failover repliceert enkel scope-instellingen, geen serveropties.
    # Daarom zetten we die hier zelf op DC2.
    $optiesDC1 = Get-DhcpServerv4OptionValue -ComputerName $PrimaryServer |
                 Where-Object { -not $_.VendorClass -and -not $_.UserClass -and -not $_.PolicyName }

    foreach ($optie in $optiesDC1) {
        $waarde = @($optie.Value)
        if ($optie.OptionId -eq 6) {
            [array]::Reverse($waarde)       # DNS-servers in omgekeerde volgorde
        }
        $bestaand = Get-DhcpServerv4OptionValue -ComputerName $PartnerServer -OptionId $optie.OptionId -ErrorAction SilentlyContinue
        if ($bestaand -and (@($bestaand.Value) -join ',') -eq ($waarde -join ',')) {
            Write-Ok ("Optie {0,-3} {1,-16} al correct: {2}" -f $optie.OptionId, $optie.Name, ($waarde -join ', '))
        }
        else {
            Set-DhcpServerv4OptionValue -ComputerName $PartnerServer -OptionId $optie.OptionId -Value $waarde
            Write-Actie ("Optie {0,-3} {1,-16} ingesteld: {2}" -f $optie.OptionId, $optie.Name, ($waarde -join ', '))
        }
    }

    # -----------------------------------------------------------------------
    Write-Stap '6. Failover-relatie (load balance) tussen DC1 en DC2'
    # -----------------------------------------------------------------------
    $scopesDC1   = @(Get-DhcpServerv4Scope -ComputerName $PrimaryServer)
    $relaties    = @(Get-DhcpServerv4Failover -ComputerName $PrimaryServer -ErrorAction SilentlyContinue)
    $inFailover  = @($relaties | ForEach-Object { $_.ScopeId } | Where-Object { $_ } | ForEach-Object { $_.IPAddressToString })
    $teKoppelen  = @($scopesDC1 | Where-Object { $inFailover -notcontains $_.ScopeId.IPAddressToString } |
                     ForEach-Object { $_.ScopeId })

    $relatie = $relaties | Where-Object { $_.Name -eq $FailoverName }

    if ($teKoppelen.Count -eq 0 -and $relatie) {
        Write-Ok 'Alle scopes van DC1 zitten al in een failover-relatie.'
    }
    elseif ($relatie) {
        Write-Actie "Relatie '$FailoverName' bestaat al, scopes toevoegen: $($teKoppelen.IPAddressToString -join ', ')"
        Add-DhcpServerv4FailoverScope -ComputerName $PrimaryServer -Name $FailoverName -ScopeId $teKoppelen
        Write-Ok 'Scopes toegevoegd aan de bestaande relatie.'
    }
    else {
        if ($teKoppelen.Count -eq 0) { throw 'Geen scopes op DC1 gevonden om te repliceren.' }
        Write-Actie "Nieuwe relatie '$FailoverName' aanmaken voor: $($teKoppelen.IPAddressToString -join ', ')"
        if (-not $SharedSecret) {
            $SharedSecret = Read-Host 'Geef het gedeelde DHCP-failovergeheim' -AsSecureString
        }
        if ($SharedSecret.Length -eq 0) { throw 'Het DHCP-failovergeheim mag niet leeg zijn.' }

        # De DHCP-cmdlet vereist een string. Beperk de omzetting tot deze aanroep.
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedSecret)
        try {
            Add-DhcpServerv4Failover -ComputerName $PrimaryServer -PartnerServer $PartnerServer `
                -Name $FailoverName -ScopeId $teKoppelen -LoadBalancePercent $LoadBalancePercent `
                -SharedSecret ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)) -Force
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        }
        Write-Ok 'Failover-relatie aangemaakt.'
    }

    # -----------------------------------------------------------------------
    Write-Stap '7. Replicatie forceren en controle'
    # -----------------------------------------------------------------------
    Invoke-DhcpServerv4FailoverReplication -ComputerName $PrimaryServer -Name $FailoverName -Force | Out-Null
    Write-Ok 'Scope-configuratie gerepliceerd naar DC2.'

    Write-Host "`nFailover-relatie (gezien vanaf DC2):" -ForegroundColor Cyan
    Get-DhcpServerv4Failover -ComputerName $PartnerServer |
        Format-List Name, PartnerServer, Mode, LoadBalancePercent, State, ScopeId

    Write-Host 'Scopes op DC2:' -ForegroundColor Cyan
    Get-DhcpServerv4Scope -ComputerName $PartnerServer | Format-Table -AutoSize

    Write-Host 'Serveropties DC1 vs DC2:' -ForegroundColor Cyan
    @($PrimaryServer, $PartnerServer) | ForEach-Object {
        $srv = $_
        Get-DhcpServerv4OptionValue -ComputerName $srv |
            Select-Object @{n='Server';e={$srv}}, OptionId, Name, @{n='Waarde';e={$_.Value -join ', '}}
    } | Format-Table -AutoSize
}
catch {
    Write-Fout $_.Exception.Message
}
finally {
    Stop-Transcript | Out-Null
}
