import csv
import sys
from ipaddress import IPv4Network
from pathlib import Path


def main():
    # Zonder argumenten gebruiken we scenario 1 in dezelfde map als dit script.
    csv_file = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("scenario1.csv")
    output_file = Path(sys.argv[2]) if len(sys.argv) > 2 else csv_file.with_suffix(".txt")
    commands = ["enable", "configure terminal"]
    active_interfaces = set()

    with csv_file.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        header = ["network", "interface", "description", "vlan",
                  "ipaddress", "subnetmask", "defaultgateway"]
        if reader.fieldnames != header:
            raise ValueError("De CSV-header moet zijn: " + ",".join(header))

        for row in reader:
            network = row["network"].strip().lower()
            interface = row["interface"].strip()
            description = row["description"].strip()
            vlan = row["vlan"].strip()
            ip = row["ipaddress"].strip()
            mask = row["subnetmask"].strip()
            gateway = row["defaultgateway"].strip()

            # Een LAN zonder interface is een netwerk achter een andere router.
            if network == "lan" and not interface:
                destination = IPv4Network(f"{ip}/{mask}", strict=False)
                commands.append(f"ip route {destination.network_address} {mask} {gateway}")
                continue

            # Ook de fysieke interface onder de subinterfaces moet actief zijn.
            if vlan != "0":
                if interface not in active_interfaces:
                    commands += [f"interface {interface}", "no shutdown", "exit"]
                    active_interfaces.add(interface)
                interface = f"{interface}.{vlan}"

            commands.append(f"interface {interface}")
            if description:
                commands.append(f"description {description}")
            if vlan != "0":
                commands.append(f"encapsulation dot1Q {vlan}")
            if network == "wan" and ip.lower() == "dhcp":
                commands.append("ip address dhcp")
            else:
                commands.append(f"ip address {ip} {mask}")
            commands += ["no shutdown", "exit"]

            if network == "wan" and ip.lower() != "dhcp" and gateway:
                commands.append(f"ip route 0.0.0.0 0.0.0.0 {gateway}")

    commands.append("end")
    output_file.write_text("\n".join(commands) + "\n", encoding="utf-8")
    print(f"Configuratie gemaakt: {output_file}")


if __name__ == "__main__":
    main()
