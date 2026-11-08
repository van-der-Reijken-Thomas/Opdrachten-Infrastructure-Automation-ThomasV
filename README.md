# Infrastructure Automation – opdrachten

Thomas van der Reijken · MCT3 · Howest

Scripts voor het vak Infrastructure Automation: PowerShell en Python voor een Raspberry Pi, Cisco-switches en -routers, een Windows-domein en een Shelly smart plug.

| Map | Opdracht | Taal |
| --- | --- | --- |
| [Opdracht 1](Opdracht%201/) | Statisch IP-adres voor een Raspberry Pi via `network-config` | PowerShell |
| [Opdracht 2](Opdracht%202/) | Cisco layer-2/3-switch configureren via SSH vanuit een CSV | Python (Netmiko) |
| [Opdracht 3](Opdracht%203/) | CLI-configuratie voor een Cisco-router genereren vanuit een CSV | Python |
| [Opdracht 4](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/) | Automatisering in een Windows-domein (DHCP, gebruikers, UPN, OU's) | PowerShell |
| [Opdracht 5](Opdracht%205/) | Shelly Plug S Gen3 configureren na een factory reset | Python |

Er staan geen wachtwoorden in deze repository. Elk script vraagt de nodige wachtwoorden pas bij het uitvoeren op, met verborgen invoer.

---

## Opdracht 1 – Raspberry Pi: statisch IP

**Script:** [`rpi_static_ip.ps1`](Opdracht%201/rpi_static_ip.ps1)

Het script zoekt de gemounte SD-kaart via het volumelabel `bootfs` en schrijft een `network-config`-bestand (Netplan/cloud-init) naar de hoofdmap van de bootpartitie. De Pi gebruikt dat bestand bij de eerste keer opstarten.

- Het bestand wordt als Linux-tekstbestand weggeschreven: UTF-8 zonder BOM, met LF-regeleindes.
- Bij herhaald uitvoeren wordt het bestand volledig vervangen en niet aangevuld. Als de inhoud al klopt, verandert het script niets.
- Het script controleert IP, gateway en DNS voordat het de SD-kaart aanraakt.
- `-WhatIf` toont wat er zou gebeuren zonder iets te schrijven.

```powershell
.\rpi_static_ip.ps1 -IPAddress 192.168.1.50 -PrefixLength 24 -Gateway 192.168.1.1 -DnsServers 192.168.1.1,1.1.1.1
```

Gebruik `-BootDriveLetter E` als er meerdere `bootfs`-partities zijn. Je hebt een Raspberry Pi OS-image met cloud-init nodig (recente Trixie-images).

---

## Opdracht 2 – Cisco-switch via SSH

**Script:** [`main.py`](Opdracht%202/main.py) · **Invoer:** [`config.csv`](Opdracht%202/config.csv)

Het script leest `config.csv` en programmeert elke switch uit de kolom `switch` rechtstreeks via SSH met [Netmiko](https://github.com/ktbyers/netmiko).

CSV-header: `vlan,description,ip address,subnetmask,switch,ports` (meerdere poorten of VLAN's scheid je met `;`).

| Rij | Herkenning | Resultaat |
| --- | --- | --- |
| Layer-3-VLAN | Alle velden ingevuld | VLAN + SVI met IP-adres |
| Layer-2-VLAN | Geen IP-gegevens | Alleen VLAN + accesspoorten |
| Management-VLAN | Description bevat `management` of `mgt` | SVI + afgeleide `ip default-gateway` (eerste host van het subnet) |
| Trunk | Description bevat `trunk` of `uplink` | Trunkpoort. Ingevulde VLAN's worden de allowed-VLAN-lijst (filtering) |

Als alle gewone VLAN's van een switch IP-gegevens hebben, zet het script `ip routing` aan. Op een 3560 wordt automatisch `switchport trunk encapsulation dot1q` toegevoegd.

Na de configuratie wordt alles opgeslagen. Het script vraagt je dan om de TFTP-server te starten en zet van elke switch de running-config op die server (`<switch-ip>-running-config.cfg`).

```bash
python -m pip install netmiko
python main.py
```

De gebruikersnaam (`admin`) en het TFTP-adres (`192.168.99.10`) staan bovenaan in `main.py`. Het SSH-/enable-wachtwoord wordt bij het starten gevraagd.

---

## Opdracht 3 – Cisco-router: configuratie genereren

**Script:** [`main.py`](Opdracht%203/main.py) · **Scenario's:** `scenario1.csv` t.e.m. `scenario4.csv`

Het script zet een CSV om naar een tekstbestand met CLI-commando's dat je rechtstreeks op de router kunt plakken.

CSV-header: `network,interface,description,vlan,ipaddress,subnetmask,defaultgateway`

| Scenario | Inhoud |
| --- | --- |
| [1](Opdracht%203/scenario1.csv) | WAN via DHCP, één LAN |
| [2](Opdracht%203/scenario2.csv) | WAN statisch met default gateway, één LAN |
| [3](Opdracht%203/scenario3.csv) | WAN statisch, LAN + achterliggende netwerken via statische routes |
| [4](Opdracht%203/scenario4.csv) | WAN via DHCP, router-on-a-stick met VLAN-subinterfaces |

Regels:

- `ipaddress` = `dhcp` op de WAN geeft `ip address dhcp`.
- Een WAN met een default gateway geeft `ip route 0.0.0.0 0.0.0.0 <gateway>`.
- Een LAN zonder interface is een netwerk achter een andere router en wordt een statische route.
- Een `vlan` verschillend van `0` geeft een subinterface (`gi0/1.<vlan>`) met `encapsulation dot1Q`. De fysieke interface wordt ook geactiveerd.

```bash
python main.py scenario4.csv              # schrijft scenario4.txt
python main.py scenario4.csv uitvoer.txt  # eigen uitvoerbestand
```

De gegenereerde uitvoer van elk scenario staat ernaast als `scenarioX.txt`.

---

## Opdracht 4 – PowerShell in een Windows-domein

**Map:** [`VanDerReijken_Thomas_PS_Windows_Domein`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/)

Omgeving: twee domeincontrollers (DC1, DC2), een memberserver (MS) en een Windows 11-client. Alle scripts draai je als Administrator. Ze controleren eerst de huidige toestand, zodat je ze meerdere keren kunt uitvoeren, en schrijven een transcript naar `C:\Opdracht`.

| Deel | Script | Uitvoeren op | Wat het doet |
| --- | --- | --- | --- |
| 1 | [`01_DHCP_Redundantie.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/01_DHCP_Redundantie/01_DHCP_Redundantie.ps1) | DC2 | DHCP-rol + tools installeren, autoriseren in AD, Server Manager-waarschuwing wegwerken, serveropties overnemen met omgekeerde DNS-volgorde, failoverrelatie (load balance) met DC1 |
| 2 | [`02_DHCP_Reservaties.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/02_DHCP_Reservaties/02_DHCP_Reservaties.ps1) | DC1 | Reservaties uit `02_DHCP_Reservaties.xlsx` aanmaken en meteen repliceren naar DC2 |
| 3a | [`03a_HomeShare_MS.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/03_Gebruikers/03a_HomeShare_MS.ps1) | MS | Home share: share-rechten Everyone – Full Control; NTFS: Administrator – Full Control, Authenticated Users – Read (this folder only) |
| 3b | [`03b_Gebruikers.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/03_Gebruikers/03b_Gebruikers.ps1) | DC1 | Gebruikers uit `03_Gebruikers.xlsx` aanmaken in de juiste OU en groep, met homemap op MS |
| 4 | [`04_UPN_Suffix.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/04_UPN_Suffix/04_UPN_Suffix.ps1) | DC1 | Extra UPN-suffix op forestniveau, standaard voor de bedrijfs-OU, en bestaande gebruikers in die OU aanpassen |
| 5 | [`05_OU_Structuur.ps1`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/05_OU_Structuur/05_OU_Structuur.ps1) | DC1 | OU-structuur uit `05_OU_Structuur.xlsx`, gebaseerd op het voorbeeldorganigram "EnYoi Holding" van [AFAS](https://help.afas.nl/help/NL/SE/Hrm_Config_OrgCrt.htm) |

De Excel-scripts gebruiken de module `ImportExcel` en installeren die zelf als ze ontbreekt.

**Gebruikersbestand:** `03_Gebruikers.xlsx` staat niet in de repo. In de plaats daarvan staat er een anoniem voorbeeld, [`03_Gebruikers.example.csv`](Opdracht%204/VanDerReijken_Thomas_PS_Windows_Domein/03_Gebruikers/03_Gebruikers.example.csv). Maak het Excel-bestand zo aan, vanuit de map `03_Gebruikers`:

```powershell
Import-Csv .\03_Gebruikers.example.csv -Encoding UTF8 |
    Export-Excel -Path .\03_Gebruikers.xlsx -WorksheetName 'Gebruikers' -AutoSize
```

Het startwachtwoord van de nieuwe gebruikers en het DHCP-failovergeheim worden bij het uitvoeren gevraagd. Het rapport bij deze opdracht is apart ingediend als ZIP.

---

## Opdracht 5 – Shelly smart plug

**Script:** [`shelly_plug_gen3.py`](Opdracht%205/shelly_plug_gen3.py)

Het script configureert een **Shelly Plug S MTR Gen3 (S3PL-00112EU)** na een factory reset. Verbind je pc eerst met het access point van de plug (`ShellyPlugSG3-<MAC>`). De plug is dan bereikbaar op `192.168.33.1`.

Het script stelt het volgende in, via de [Shelly RPC-API](https://shelly-api-docs.shelly.cloud/):

- de naam van de plug (via `--name`)
- de uitgang staat **uit** na een herstart
- alle leds uit
- MQTT met broker `172.23.83.254`, met de plugnaam als topic
- ongebruikte services uit (Bluetooth-RPC, Matter, outbound WebSocket, debug, UDP-RPC)
- maximaal vermogen 2200 W
- wifi verbinden met `Howest-IoT`
- Shelly Cloud standaard **uit**, aan met `--cloud`

Het access point van de plug wordt pas uitgeschakeld als wifi en MQTT werken en alle instellingen gecontroleerd zijn. Als er iets misgaat, kun je de plug dus nog via `192.168.33.1` bereiken.

```bash
python -m pip install requests
python shelly_plug_gen3.py --name VanDerReijken-Thomas-Outlet1
python shelly_plug_gen3.py --name VanDerReijken-Thomas-Outlet1 --cloud
python shelly_plug_gen3.py --name VanDerReijken-Thomas-Outlet1 --auto-connect   # Windows: verbindt zelf met de Shelly-AP
```

Het wifiwachtwoord van `Howest-IoT` wordt bij het starten verborgen gevraagd. Gebruik `--mac` om een plug te kiezen als er meerdere in de buurt zijn.

---

## Vereisten

- **PowerShell 5.1** op Windows (opdracht 1 en 4). Voor opdracht 4 heb je ook de modules ActiveDirectory en DhcpServer nodig.
- **Python 3** met `netmiko` (opdracht 2) en `requests` (opdracht 5). Opdracht 3 gebruikt alleen de standaardbibliotheek.

## AI-gebruik

Bij het schrijven, controleren en documenteren van deze scripts is AI gebruikt (ChatGPT/Codex en Claude), onder andere voor de controle op gevoelige gegevens, de `.gitignore` en deze README.
