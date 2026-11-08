#!/usr/bin/env python3
"""Configureer Shelly Plug S MTR Gen3 (S3PL-00112EU) na factory reset.

Vereist: pip install requests
Voorbeeld: python shelly_plug_gen3.py --name vander-Thomas-Outlet1
           python shelly_plug_gen3.py --name vander-Thomas-Outlet1 --cloud
           python shelly_plug_gen3.py --name vander-Thomas-Outlet1 --auto-connect
"""

import argparse
import getpass
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from xml.sax.saxutils import escape

import requests

PLUG_IP = "192.168.33.1"
MODEL = "S3PL-00112EU"
AP_PATTERN = re.compile(r"^ShellyPlugSG3-([0-9A-Fa-f]{12})$")
WIFI_SSID = "Howest-IoT"
MQTT_BROKER = "172.23.83.254:1883"


class ShellyError(Exception):
    pass


class Shelly:
    def __init__(self, ip):
        self.url = f"http://{ip}/rpc"
        self.session = requests.Session()
        # Proxy-instellingen mogen lokaal verkeer naar 192.168.33.1 niet onderscheppen.
        self.session.trust_env = False

    def call(self, method, **params):
        payload = {"id": 1, "method": method, "params": params}
        try:
            response = self.session.post(self.url, json=payload, timeout=5)
            response.raise_for_status()
            result = response.json()
        except (requests.RequestException, ValueError) as exc:
            raise ShellyError(f"{method}: geen geldig antwoord: {exc}") from exc
        if isinstance(result, dict) and result.get("error"):
            raise ShellyError(f"{method}: {result['error']}")
        if isinstance(result, dict):
            return result.get("result", result.get("params", result))
        return result

    def configure(self, method, config, **extra):
        print(f"  -> {method}")
        result = self.call(method, config=config, **extra)
        return isinstance(result, dict) and bool(result.get("restart_required"))


def ask_wifi_password():
    """Vraag het wifi-wachtwoord onzichtbaar op (wordt nergens opgeslagen)."""
    while True:
        password = getpass.getpass(f"Wifi-wachtwoord voor {WIFI_SSID}: ")
        if not 8 <= len(password) <= 63:
            print("Een WPA2-wachtwoord moet 8 tot 63 tekens lang zijn. Probeer opnieuw.")
            continue
        if getpass.getpass("Herhaal wachtwoord: ") != password:
            print("Wachtwoorden komen niet overeen. Probeer opnieuw.")
            continue
        return password


def connect_to_shelly_ap(mac_suffix=None):
    """Optioneel: kies en verbind automatisch met een open Shelly-AP op Windows."""
    if platform.system() != "Windows":
        raise ShellyError("--auto-connect is enkel voor Windows; verbind anders handmatig met de Shelly-AP.")

    scan = subprocess.run(
        ["netsh", "wlan", "show", "networks"], capture_output=True, text=True, errors="replace"
    )
    if scan.returncode != 0:
        raise ShellyError("Windows kan de wifi-netwerken niet uitlezen (netsh wlan show networks).")

    found = []
    for line in scan.stdout.splitlines():
        match = re.match(r"\s*SSID\s+\d+\s*:\s*(.+?)\s*$", line)
        if match and AP_PATTERN.fullmatch(match.group(1)):
            ssid = match.group(1)
            if not mac_suffix or ssid.upper().endswith(mac_suffix.upper()):
                found.append(ssid)

    if not found:
        raise ShellyError("Geen ShellyPlugSG3-XXXXXXXXXXXX gevonden. Scan opnieuw of verbind handmatig.")
    if len(found) > 1:
        raise ShellyError(
            "Meerdere Shelly-AP's gevonden: " + ", ".join(found)
            + ". Gebruik --mac om er één te selecteren."
        )

    ssid = found[0]
    print(f"Verbinden met Shelly-AP: {ssid}")
    profile_xml = f'''<?xml version="1.0" encoding="utf-8"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>{escape(ssid)}</name>
  <SSIDConfig><SSID><name>{escape(ssid)}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>manual</connectionMode>
  <MSM><security><authEncryption><authentication>open</authentication>
  <encryption>none</encryption><useOneX>false</useOneX>
  </authEncryption></security></MSM>
</WLANProfile>'''
    with tempfile.TemporaryDirectory() as tmp:
        file = Path(tmp) / "shelly_wifi.xml"
        file.write_text(profile_xml, encoding="utf-8")
        add = subprocess.run(
            ["netsh", "wlan", "add", "profile", f"filename={file}", "user=current"],
            capture_output=True, text=True, errors="replace"
        )
        if add.returncode != 0:
            raise ShellyError(f"Wifi-profiel toevoegen mislukt: {add.stdout} {add.stderr}")
    connect = subprocess.run(
        ["netsh", "wlan", "connect", f"name={ssid}", f"ssid={ssid}"],
        capture_output=True, text=True, errors="replace"
    )
    if connect.returncode != 0:
        raise ShellyError(f"Verbinden mislukt: {connect.stdout} {connect.stderr}")


def wait_for_rpc(plug, deadline_s=45):
    until = time.monotonic() + deadline_s
    while time.monotonic() < until:
        try:
            return plug.call("Shelly.GetDeviceInfo")
        except ShellyError:
            time.sleep(2)
    raise ShellyError("Plug niet bereikbaar via 192.168.33.1. Controleer de wifi-verbinding.")


def wait_for_sta(plug, deadline_s=45):
    until = time.monotonic() + deadline_s
    while time.monotonic() < until:
        try:
            state = plug.call("WiFi.GetStatus")
            if state.get("ssid") == WIFI_SSID and state.get("sta_ip"):
                return state["sta_ip"]
        except ShellyError:
            pass
        time.sleep(2)
    raise ShellyError(
        f"Geen IP op {WIFI_SSID} gekregen (verkeerd wachtwoord?). AP blijft actief om opnieuw te proberen."
    )


def wait_for_mqtt(plug, deadline_s=35):
    until = time.monotonic() + deadline_s
    while time.monotonic() < until:
        try:
            if plug.call("MQTT.GetStatus").get("connected") is True:
                return True
        except ShellyError:
            pass
        time.sleep(2)
    return False


def verify_settings(plug, name, cloud_on, initial_config):
    """Controleer ingestelde waarden voordat de herstel-AP wordt uitgeschakeld."""
    sys_cfg = plug.call("Sys.GetConfig")
    sw_cfg = plug.call("Switch.GetConfig", id=0)
    led_cfg = plug.call("PLUGS_UI.GetConfig")
    mqtt_cfg = plug.call("MQTT.GetConfig")
    cloud_cfg = plug.call("Cloud.GetConfig")
    wifi_cfg = plug.call("WiFi.GetConfig")

    checks = {
        "naam": sys_cfg.get("device", {}).get("name") == name,
        "uit na herstart": sw_cfg.get("initial_state") == "off",
        "maximaal 2200 W": sw_cfg.get("power_limit") == 2200,
        "leds uit": led_cfg.get("leds", {}).get("mode") == "off",
        "MQTT ingeschakeld": mqtt_cfg.get("enable") is True,
        "MQTT-broker": mqtt_cfg.get("server") == MQTT_BROKER,
        "MQTT-topicprefix": mqtt_cfg.get("topic_prefix") == name,
        "MQTT-statusupdates": mqtt_cfg.get("status_ntf") is True,
        "cloud": cloud_cfg.get("enable") is cloud_on,
        "wifi-netwerk": wifi_cfg.get("sta", {}).get("ssid") == WIFI_SSID,
    }
    if "matter" in initial_config:
        checks["Matter uit"] = plug.call("Matter.GetConfig").get("enable") is False
    if "ws" in initial_config:
        checks["outbound WebSocket uit"] = plug.call("Ws.GetConfig").get("enable") is False
    if "ble" in initial_config:
        ble_cfg = plug.call("BLE.GetConfig")
        checks["Bluetooth-RPC uit"] = ble_cfg.get("rpc", {}).get("enable") is False
        if "enable" in ble_cfg:
            checks["Bluetooth uit"] = ble_cfg.get("enable") is False

    wrong = [key for key, ok in checks.items() if not ok]
    for key, ok in checks.items():
        print(f"  {'OK' if ok else 'FOUT'}: {key}")
    if wrong:
        raise ShellyError("Niet alle instellingen zijn correct: " + ", ".join(wrong) + ". AP blijft aan.")


def main():
    parser = argparse.ArgumentParser(description="Configureer Shelly Plug S MTR Gen3 na factory reset")
    parser.add_argument("--name", required=True, help="bv. vander-Thomas-Outlet1")
    parser.add_argument("--cloud", action="store_true", help="Shelly Cloud inschakelen (standaard UIT)")
    parser.add_argument("--auto-connect", action="store_true", help="Verbind zelf met de Shelly-AP (Windows)")
    parser.add_argument("--mac", help="(deel van) MAC-adres om de juiste Shelly-AP te kiezen")
    parser.add_argument("--ip", default=PLUG_IP, help="Huidig IP-adres van de plug")
    args = parser.parse_args()

    if not re.fullmatch(r"[^/+#?%\s]+-[^/+#?%\s]+-Outlet1", args.name):
        parser.error("Gebruik --name Familienaam-Voornaam-Outlet1 (zonder spaties of MQTT-wildcards).")
    if args.auto_connect and args.ip != PLUG_IP:
        parser.error("--auto-connect werkt enkel met het fabrieksadres 192.168.33.1.")

    # Eerst vragen, zodat je niet halverwege de configuratie moet typen.
    wifi_password = ask_wifi_password()

    if args.auto_connect:
        connect_to_shelly_ap(args.mac)

    plug = Shelly(args.ip)
    print("Contact zoeken met de Shelly...")
    device = wait_for_rpc(plug)
    print(f"Gevonden: {device.get('id')} | {device.get('model')} | fw {device.get('ver')}")
    if device.get("model") != MODEL or device.get("gen") != 3:
        raise ShellyError("Dit is niet de verwachte Shelly Plug S MTR Gen3 (S3PL-00112EU)!")
    if device.get("auth_en"):
        raise ShellyError("Authenticatie is actief; deze opdracht verwacht een factory reset zonder wachtwoord.")

    all_config = plug.call("Shelly.GetConfig")
    if not isinstance(all_config, dict):
        raise ShellyError("Shelly.GetConfig gaf geen geldige configuratie terug.")
    print("Configuratie toepassen (wifi-AP blijft voorlopig ingeschakeld)...")

    # Schakel voor de zekerheid ook NU al de uitgang uit.
    plug.call("Switch.Set", id=0, on=False)
    must_reboot = False

    sys_cfg = all_config.get("sys", {})
    device_patch = {"name": args.name}
    if "discoverable" in sys_cfg.get("device", {}):
        device_patch["discoverable"] = False
    sys_patch = {"device": device_patch}
    if "rpc_udp" in sys_cfg:
        sys_patch["rpc_udp"] = {"listen_port": None}
    debug = sys_cfg.get("debug", {})
    debug_patch = {}
    if "mqtt" in debug:
        debug_patch["mqtt"] = {"enable": False}
    if "websocket" in debug:
        debug_patch["websocket"] = {"enable": False}
    if "udp" in debug:
        debug_patch["udp"] = {"addr": None}
    if "file_log" in debug:
        debug_patch["file_log"] = {"enable": False}
    if debug_patch:
        sys_patch["debug"] = debug_patch
    must_reboot |= plug.configure("Sys.SetConfig", sys_patch)

    must_reboot |= plug.configure(
        "Switch.SetConfig",
        {"initial_state": "off", "power_limit": 2200, "auto_on": False}, id=0,
    )
    must_reboot |= plug.configure("PLUGS_UI.SetConfig", {"leds": {"mode": "off"}})
    must_reboot |= plug.configure(
        "MQTT.SetConfig",
        {"enable": True, "server": MQTT_BROKER, "topic_prefix": args.name,
         "status_ntf": True, "rpc_ntf": True},
    )
    must_reboot |= plug.configure("Cloud.SetConfig", {"enable": args.cloud})

    if "ws" in all_config:
        must_reboot |= plug.configure("Ws.SetConfig", {"enable": False})
    if "matter" in all_config:
        must_reboot |= plug.configure("Matter.SetConfig", {"enable": False})
    if "ble" in all_config:
        ble_cfg = all_config["ble"]
        ble_patch = {"rpc": {"enable": False}}
        # Op firmware <2.0 bestaat ook de algemene enable-instelling.
        if "enable" in ble_cfg:
            ble_patch["enable"] = False
        must_reboot |= plug.configure("BLE.SetConfig", ble_patch)

    # Eerst verbinding met de school-wifi maken, ZONDER de lokale AP kwijt te raken.
    print("Verbinden met Howest-IoT (Shelly-AP blijft voorlopig actief)...")
    must_reboot |= plug.configure(
        "WiFi.SetConfig",
        {"sta": {"enable": True, "ssid": WIFI_SSID, "pass": wifi_password}},
    )
    sta_ip = wait_for_sta(plug)
    print(f"School-wifi verbonden! IP-adres van de Shelly: {sta_ip}")

    # Voor MQTT / BLE kan Shelly een herstart vereisen.
    if must_reboot:
        print("Herstart uitvoeren om de gewijzigde services te activeren...")
        try:
            plug.call("Shelly.Reboot")
        except ShellyError:
            # Een onderbroken HTTP-verbinding bij reboot is normaal.
            pass
        time.sleep(5)
        wait_for_rpc(plug)
        sta_ip = wait_for_sta(plug)
        print(f"Na herstart opnieuw verbonden met Howest-IoT: {sta_ip}")

    if not wait_for_mqtt(plug):
        raise ShellyError(
            f"MQTT-configuratie opgeslagen, maar geen brokerconnectie met {MQTT_BROKER}. "
            "De Shelly-AP blijft aan om dit te onderzoeken."
        )
    print("MQTT is verbonden.")

    print("Instellingen verifiëren...")
    verify_settings(plug, args.name, args.cloud, all_config)

    # Tot hier is herstel via 192.168.33.1 nog mogelijk. Schakel de AP PAS NU uit.
    print("Laatste stap: de ongebruikte Shelly-AP uitschakelen...")
    try:
        plug.configure("WiFi.SetConfig", {"ap": {"enable": False}})
    except ShellyError:
        print("Opmerking: verbinding viel weg tijdens uitschakelen van de AP; controleer via het nieuwe IP.")

    print("\nKLAAR")
    print(f"Naam en MQTT-topicprefix : {args.name}")
    print(f"MQTT-broker             : {MQTT_BROKER}")
    print(f"Cloud                   : {'AAN' if args.cloud else 'UIT'}")
    print("Uitgang na herstart     : UIT")
    print("Leds                    : UIT")
    print("Maximaal vermogen       : 2200 W")
    print(f"Webinterface nieuw IP   : http://{sta_ip}")
    print("Je pc kan de wifi-verbinding verliezen doordat de Shelly-AP nu uit staat.")


if __name__ == "__main__":
    try:
        main()
    except ShellyError as exc:
        print(f"\nFOUT: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nAfgebroken door gebruiker.", file=sys.stderr)
        sys.exit(1)
