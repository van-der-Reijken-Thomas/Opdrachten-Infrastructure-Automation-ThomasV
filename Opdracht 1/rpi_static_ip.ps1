#Requires -Version 5.1
<#
.SYNOPSIS
Schrijft een statisch IPv4-adres voor Ethernet naar de bootfs-partitie.
.DESCRIPTION
Voor Windows met een gemounte Raspberry Pi OS SD-kaart, voor de eerste boot.
Vereist een OS-image met cloud-init/Netplan, zoals recente Trixie-images.
Het bestand network-config wordt volledig vervangen: UTF-8 zonder BOM, LF.
Dit vervangt ook eventuele bestaande wifi- of andere netwerkconfiguratie.
.EXAMPLE
.\rpi_static_ip.ps1 -IPAddress 192.168.1.50 -PrefixLength 24 -Gateway 192.168.1.1 -DnsServers 192.168.1.1,1.1.1.1
.EXAMPLE
.\rpi_static_ip.ps1 -IPAddress 192.168.1.50 -Gateway 192.168.1.1 -DnsServers 192.168.1.1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$IPAddress,

    [ValidateRange(1, 30)]
    [int]$PrefixLength = 24,

    [Parameter(Mandatory = $true)]
    [string]$Gateway,

    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 10)]
    [string[]]$DnsServers,

    [ValidatePattern('\A[a-zA-Z][a-zA-Z0-9_.-]{0,14}\z')]
    [string]$InterfaceName = 'eth0',

    [ValidatePattern('\A[a-zA-Z]\z')]
    [string]$BootDriveLetter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-IPv4Number {
    param([string]$Value, [string]$ParameterName)

    # Alleen vier decimale octetten; geen verkorte adressen of voorloopnullen.
    $pattern = '\A(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\z'
    if ($Value -cnotmatch $pattern) {
        throw "$ParameterName bevat geen geldig IPv4-adres: '$Value'."
    }

    [uint64]$number = 0
    foreach ($octet in $Value.Split('.')) {
        if ([int]$octet -gt 255) {
            throw "$ParameterName bevat een IPv4-octet groter dan 255: '$Value'."
        }
        $number = ($number * 256) + [int]$octet
    }
    return $number
}

# Controleer alle invoer voordat de SD-kaart wordt benaderd.
$ipNumber = ConvertTo-IPv4Number $IPAddress 'IPAddress'
$gatewayNumber = ConvertTo-IPv4Number $Gateway 'Gateway'
foreach ($dns in $DnsServers) {
    $null = ConvertTo-IPv4Number $dns 'DnsServers'
}

# controle op gewone LAN-subnetten (/1 tot /30).
[uint64]$subnetSize = [math]::Pow(2, 32 - $PrefixLength)
[uint64]$networkNumber = $ipNumber - ($ipNumber % $subnetSize)
[uint64]$broadcastNumber = $networkNumber + $subnetSize - 1
if ($ipNumber -eq $networkNumber -or $ipNumber -eq $broadcastNumber) {
    throw 'IPAddress mag geen netwerkadres of broadcastadres zijn.'
}
if ($gatewayNumber -le $networkNumber -or $gatewayNumber -ge $broadcastNumber) {
    throw 'Gateway moet een bruikbaar adres binnen hetzelfde subnet zijn.'
}
if ($ipNumber -eq $gatewayNumber) {
    throw 'IPAddress en Gateway moeten verschillend zijn.'
}

if (-not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
    throw 'Get-Volume ontbreekt. Voer dit script uit op Windows met de Storage-module.'
}
$volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystemLabel -eq 'bootfs' })
if ($BootDriveLetter) {
    $volumes = @($volumes | Where-Object { $_.DriveLetter -eq $BootDriveLetter })
}
if ($volumes.Count -eq 0) {
    throw 'Geen passende bootfs-partitie gevonden. Plaats de SD-kaart en controleer het volumelabel en de eventuele -BootDriveLetter.'
}
if ($volumes.Count -gt 1) {
    throw 'Meerdere bootfs-partities gevonden. Geef de juiste stationsletter op met -BootDriveLetter E (zonder dubbele punt).'
}
if (-not $volumes[0].DriveLetter) {
    throw 'De bootfs-partitie heeft geen stationsletter. Ken er een toe via Windows Schijfbeheer en probeer opnieuw.'
}

$bootRoot = '{0}:\' -f $volumes[0].DriveLetter
if (-not (Test-Path -LiteralPath (Join-Path $bootRoot 'config.txt') -PathType Leaf)) {
    throw "Geen config.txt gevonden op $bootRoot. Controleer of dit de Raspberry Pi-bootpartitie is."
}
$destination = Join-Path $bootRoot 'network-config'

# Raspberry Pi OS gebruikt Netplan met NetworkManager. De network:-wrapper
# volgt het formaat van Raspberry Pi Imager voor Raspberry Pi OS.
# YAML gebruikt spaties, geen tabs. De bestandsnaam heeft geen extensie.
$lines = @(
    'network:'
    '  version: 2'
    '  renderer: NetworkManager'
    '  ethernets:'
    "    ${InterfaceName}:"
    '      dhcp4: false'
    '      dhcp6: false'
    '      addresses:'
    "        - $IPAddress/$PrefixLength"
    '      routes:'
    '        - to: 0.0.0.0/0'
    "          via: $Gateway"
    '      nameservers:'
    '        addresses:'
)
foreach ($dns in $DnsServers) {
    $lines += "          - $dns"
}

# Expliciete LF (0x0A), ook onder Windows. Sluit af met precies een LF.
$yaml = ($lines -join "`n") + "`n"
$encoding = [System.Text.UTF8Encoding]::new($false)
$bytes = $encoding.GetBytes($yaml)

# Vergelijk bytes zodat ook een bestaande BOM of CRLF wordt gecorrigeerd.
if (Test-Path -LiteralPath $destination -PathType Leaf) {
    $existingBytes = [System.IO.File]::ReadAllBytes($destination)
    if ([Convert]::ToBase64String($existingBytes) -ceq [Convert]::ToBase64String($bytes)) {
        Write-Host "Ongewijzigd: $destination bevat al de juiste configuratie."
        return
    }
}

if ($PSCmdlet.ShouldProcess($destination, 'Volledige Ethernet-configuratie schrijven (bestaande inhoud vervangen)')) {
    try {
        [System.IO.File]::WriteAllBytes($destination, $bytes)
    }
    catch {
        throw "Schrijven naar '$destination' mislukt. Controleer schrijfbeveiliging en toegangsrechten. $($_.Exception.Message)"
    }
    Write-Host "Aangemaakt/bijgewerkt: $destination (UTF-8 zonder BOM, Linux LF)."
    Write-Host 'Werp de SD-kaart veilig uit en plaats ze in de Raspberry Pi voor de eerste boot.'
}
