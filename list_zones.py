#!/usr/bin/env python3
"""
list_zones.py

Finds every Nuvo zone on the local network via SSDP and prints its
friendly name alongside the member MAC needed for config.conf -- so you
don't need to packet-capture your own traffic just to find one MAC
address.

Usage:
    list_zones.py [--timeout SECONDS]
"""

import argparse
import re
import socket
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

ZONE_SERVICE_TYPE = "urn:schemas-nuvotechnologies-com:service:Zone:1"
DEVICE_NS = {"d": "urn:schemas-upnp-org:device-1-0"}

# The device UUID format Nuvo zones use is 00000000-0000-0000-0000-<mac>
UUID_MAC_RE = re.compile(r"uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-([0-9a-f]{12})", re.IGNORECASE)


def ssdp_discover(timeout):
    """Broad SSDP search (ssdp:all) -- narrower, service-type-specific
    searches aren't reliably answered by the Nuvo's embedded UPnP stack,
    so we cast a wide net here and filter by service type afterward once
    we have each device's actual description."""
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
            m = re.search(r"LOCATION:\s*(\S+)", text, re.IGNORECASE)
            if m:
                locations.add(m.group(1).strip())
    except socket.timeout:
        pass
    finally:
        sock.close()
    return locations


def describe(location):
    """Fetch a device description and return (friendly_name, member_mac,
    zone_control_url, is_nuvo_zone) -- is_nuvo_zone is False for other
    UPnP devices on the network that respond to the broad ssdp:all
    search (printers, TVs, etc.) so callers can filter those out."""
    with urllib.request.urlopen(location, timeout=5) as resp:
        xml_bytes = resp.read()
    root = ET.fromstring(xml_bytes)

    name = root.findtext(".//d:device/d:friendlyName", default="(no friendlyName)", namespaces=DEVICE_NS)
    udn = root.findtext(".//d:device/d:UDN", default="", namespaces=DEVICE_NS)

    zone_control_url = None
    service_types = set()
    for s in root.findall(".//d:service", DEVICE_NS):
        stype = s.findtext("d:serviceType", default="", namespaces=DEVICE_NS)
        service_types.add(stype)
        if stype == ZONE_SERVICE_TYPE:
            curl = s.findtext("d:controlURL", default="", namespaces=DEVICE_NS)
            if curl:
                zone_control_url = urljoin(location, curl)
    is_nuvo_zone = ZONE_SERVICE_TYPE in service_types

    mac = None
    m = UUID_MAC_RE.search(udn)
    if m:
        mac = m.group(1).lower()

    return name, mac, zone_control_url, is_nuvo_zone


def get_zone_title(zone_control_url):
    """Call the Zone service's Get action and return its Title (the
    zone's actual configured name, e.g. "Kitchen") -- friendlyName in
    the device description is just boilerplate ("NuVo Zone <mac>"), not
    useful for telling zones apart, so this is the field that matters."""
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" '
        'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:Get xmlns:u="urn:schemas-nuvotechnologies-com:service:Zone:1">'
        "</u:Get></s:Body></s:Envelope>"
    ).encode()

    req = urllib.request.Request(
        zone_control_url,
        data=body,
        headers={
            "SOAPAction": f'"{ZONE_SERVICE_TYPE}#Get"',
            "Content-Type": 'text/xml; charset="utf-8"',
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        xml_bytes = resp.read()

    m = re.search(rb"<Title>([^<]*)</Title>", xml_bytes)
    if m:
        return m.group(1).decode(errors="replace")
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, default=4)
    args = parser.parse_args()

    print(f"Searching for Nuvo zones ({args.timeout:.0f}s)...\n", file=sys.stderr)
    locations = ssdp_discover(args.timeout)

    if not locations:
        sys.exit("No UPnP devices responded at all. Check that this machine "
                 "is on the same network/broadcast domain as your Nuvo "
                 "zones (SSDP relies on multicast, which some mesh WiFi "
                 "setups or VLANs don't pass through).")

    results = []
    skipped_non_nuvo = 0
    for loc in sorted(locations):
        try:
            fallback_name, mac, zone_control_url, is_nuvo_zone = describe(loc)
        except Exception as e:
            print(f"Warning: failed to describe {loc}: {e}", file=sys.stderr)
            continue

        if not is_nuvo_zone:
            skipped_non_nuvo += 1
            continue

        title = None
        if zone_control_url:
            try:
                title = get_zone_title(zone_control_url)
            except Exception as e:
                print(f"Warning: failed to read zone title for {loc}: {e}", file=sys.stderr)

        display_name = title or fallback_name
        results.append((display_name, mac, loc))

    if skipped_non_nuvo:
        print(f"(ignored {skipped_non_nuvo} other UPnP device(s) on the network "
              f"that aren't Nuvo zones)\n", file=sys.stderr)

    if not results:
        sys.exit("Found other UPnP devices, but none were Nuvo zones. "
                 "Confirm the zone is powered on.")

    name_width = max(len(r[0]) for r in results) + 2
    print(f"{'Zone name':<{name_width}}{'NUVO_MEMBER_MAC':<16}Device description URL")
    print("-" * (name_width + 16 + 40))
    for name, mac, loc in results:
        print(f"{name:<{name_width}}{mac or '(unknown)':<16}{loc}")

    print(f"\nCopy the MAC for your zone into config.conf as, e.g.:")
    if results:
        example_mac = results[0][1] or "000000000000"
        example_name = results[0][0]
        print(f'  NUVO_MEMBER_MAC="{example_mac}"')
        print(f'  NUVO_ZONE_NAME="{example_name}"')


if __name__ == "__main__":
    main()
