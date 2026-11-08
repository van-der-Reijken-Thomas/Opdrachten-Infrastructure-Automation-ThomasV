# Installeer eerst Netmiko: python -m pip install netmiko
import csv
from getpass import getpass
import re
from ipaddress import IPv4Network
from pathlib import Path

from netmiko import ConnectHandler

USERNAME = "admin"
TFTP_SERVER = "192.168.99.10"
HEADER = ["vlan", "description", "ip address", "subnetmask", "switch", "ports"]


def is_trunk(row):
    description = row["description"].lower()
    return "trunk" in description or "uplink" in description


def make_commands(rows, dot1q=False):
    vlans = [row for row in rows if not is_trunk(row)]
    routing = bool(vlans) and all(row["ip address"] and row["subnetmask"]
                                  for row in vlans)
    commands = ["ip routing" if routing else "no ip routing"]

    for row in rows:
        vlan = row["vlan"]
        description = row["description"]
        ip = row["ip address"]
        mask = row["subnetmask"]
        ports = [port.strip() for port in row["ports"].split(";") if port.strip()]

        if is_trunk(row):
            for port in ports:
                commands += [f"interface {port}", "switchport",
                             f"description {description}"]
                if dot1q:  # De oudere 3560 vereist expliciet 802.1Q.
                    commands.append("switchport trunk encapsulation dot1q")
                allowed = vlan.replace(";", ",").replace(" ", "") or "all"
                commands += ["switchport mode trunk",
                             f"switchport trunk allowed vlan {allowed}",
                             "no shutdown", "exit"]
            continue

        commands.append(f"vlan {vlan}")
        if description:
            commands.append(f"name {description.replace(' ', '_')}")
        commands.append("exit")

        if ip and mask:
            commands += [f"interface vlan {vlan}", f"ip address {ip} {mask}",
                         "no shutdown", "exit"]
            if not routing and any(word in description.lower()
                                   for word in ("management", "mgt")):
                network = IPv4Network(f"{ip}/{mask}", strict=False)
                gateway = next(network.hosts())
                commands.append(f"ip default-gateway {gateway}")

        for port in ports:
            commands += [f"interface {port}", "switchport",
                         "switchport mode access", f"switchport access vlan {vlan}",
                         f"description {description}" if description else "no description",
                         "no shutdown", "exit"]

    return commands


def backup(connection, host):
    filename = f"{host}-running-config.cfg"
    # Cisco stelt eerst twee vragen. Wacht telkens op de verwachte vraag.
    connection.send_command("copy running-config tftp:",
                            expect_string=r"Address or name of remote host.*\?")
    connection.send_command(TFTP_SERVER, expect_string=r"Destination filename.*\?")
    output = connection.send_command(filename, expect_string=r"#", read_timeout=120)
    print(output)
    if not re.search(r"\d+ bytes copied", output):
        raise RuntimeError(f"TFTP-backup van {host} niet bevestigd; controleer de server.")
    print(f"Backup op TFTP-server: {filename}")


def main():
    switches = {}
    with Path(__file__).with_name("config.csv").open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        if reader.fieldnames != HEADER:
            raise ValueError("De CSV-header moet zijn: " + ",".join(HEADER))
        for row in reader:
            row = {key: value.strip() for key, value in row.items()}
            if bool(row["ip address"]) != bool(row["subnetmask"]):
                raise ValueError("Vul IP-adres en subnetmask samen in, of laat beide leeg.")
            switches.setdefault(row["switch"], []).append(row)

    password = getpass("SSH- en enable-wachtwoord voor de switches: ")
    if not password:
        raise ValueError("Het switchwachtwoord mag niet leeg zijn.")
    login = dict(device_type="cisco_ios", username=USERNAME,
                 password=password, secret=password)

    # Eerst alle switches configureren en opslaan.
    for host, rows in switches.items():
        print(f"Switch {host} configureren...")
        with ConnectHandler(host=host, **login) as connection:
            connection.enable()
            dot1q = "3560" in connection.send_command("show version")
            commands = make_commands(rows, dot1q)
            print(connection.send_config_set(commands, error_pattern=r"%"))
            print(connection.save_config())

    # De TFTP-server start je zelf op je pc; daarna kopieert de switch zijn config.
    input(f"Start je TFTP-server op {TFTP_SERVER} (schrijven toestaan) en druk op Enter... ")
    for host in switches:
        with ConnectHandler(host=host, **login) as connection:
            connection.enable()
            backup(connection, host)


if __name__ == "__main__":
    main()
