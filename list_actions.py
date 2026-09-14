#!/usr/bin/env python3
"""
list_actions.py

Enumerates every UPnP service and action a Nuvo zone (or any UPnP device)
publishes, by reading its device description XML and then each service's
SCPD (Service Control Protocol Description) document.

Usage:
    list_actions.py <device-description-url>
    list_actions.py --discover <member_mac>   # find the URL via SSDP first

Example:
    ./list_actions.py http://192.168.50.145:58587/00000000-0000-0000-0000-0025ed1e7c0b.xml
"""

import argparse
import socket
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

DEVICE_NS = {"d": "urn:schemas-upnp-org:device-1-0"}
SCPD_NS = {"s": "urn:schemas-upnp-org:service-1-0"}


def ssdp_discover(member_mac, timeout=4):
    msg = (
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        "ST: ssdp:all\r\n"
        "\r\n"
    ).encode()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(timeout)
    sock.sendto(msg, ("239.255.255.250", 1900))

    locations = set()
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            sock.settimeout(max(0.1, deadline - time.time()))
            data, _ = sock.recvfrom(65507)
            text = data.decode(errors="replace")
            if member_mac.lower() not in text.lower():
                continue
            m = re.search(r"LOCATION:\s*(\S+)", text, re.IGNORECASE)
            if m:
                locations.add(m.group(1).strip())
    except socket.timeout:
        pass
    finally:
        sock.close()
    return locations


def fetch_xml(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return ET.fromstring(resp.read())


def list_services(device_description_url):
    root = fetch_xml(device_description_url)
    services = []
    for service in root.findall(".//d:service", DEVICE_NS):
        stype = service.findtext("d:serviceType", default="", namespaces=DEVICE_NS)
        sid = service.findtext("d:serviceId", default="", namespaces=DEVICE_NS)
        scpd = service.findtext("d:SCPDURL", default="", namespaces=DEVICE_NS)
        control = service.findtext("d:controlURL", default="", namespaces=DEVICE_NS)
        services.append({
            "type": stype,
            "id": sid,
            "scpd_url": urljoin(device_description_url, scpd) if scpd else None,
            "control_url": urljoin(device_description_url, control) if control else None,
        })
    return services


def list_actions(scpd_url):
    root = fetch_xml(scpd_url)
    actions = []
    for action in root.findall(".//s:action", SCPD_NS):
        name = action.findtext("s:name", default="", namespaces=SCPD_NS)
        args = []
        for arg in action.findall(".//s:argument", SCPD_NS):
            arg_name = arg.findtext("s:name", default="", namespaces=SCPD_NS)
            direction = arg.findtext("s:direction", default="", namespaces=SCPD_NS)
            related = arg.findtext("s:relatedStateVariable", default="", namespaces=SCPD_NS)
            args.append((arg_name, direction, related))
        actions.append((name, args))
    return actions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url", nargs="?", help="Device description XML URL")
    parser.add_argument("--discover", metavar="MEMBER_MAC",
                         help="Find the device via SSDP by member MAC instead of a URL")
    args = parser.parse_args()

    if args.discover:
        locations = ssdp_discover(args.discover)
        if not locations:
            sys.exit(f"No device found for MAC {args.discover}")
        device_url = sorted(locations)[0]
        print(f"Discovered device description: {device_url}\n")
    elif args.url:
        device_url = args.url
    else:
        parser.print_help()
        sys.exit(1)

    services = list_services(device_url)
    if not services:
        sys.exit("No services found in device description.")

    for svc in services:
        print("=" * 70)
        print(f"Service type: {svc['type']}")
        print(f"Service ID:   {svc['id']}")
        print(f"Control URL:  {svc['control_url']}")
        if not svc["scpd_url"]:
            print("(no SCPD URL published for this service)")
            continue
        try:
            actions = list_actions(svc["scpd_url"])
        except Exception as e:
            print(f"Failed to fetch/parse SCPD ({svc['scpd_url']}): {e}")
            continue
        if not actions:
            print("(no actions listed)")
        for name, arglist in actions:
            print(f"  - {name}")
            for arg_name, direction, related in arglist:
                print(f"      {direction:<4} {arg_name}  (state var: {related})")
        print()


if __name__ == "__main__":
    main()
