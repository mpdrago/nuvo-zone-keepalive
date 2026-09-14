#!/usr/bin/env python3
"""
nuvo-zone-keepalive: discovery poller

Finds a Nuvo zone via SSDP by its member MAC address, reads its device
description XML for the real control URLs of the Zone and AVTransport
services, and atomically writes them to a cache file.

Intended to run periodically (every 30-60s) via cron or a systemd timer,
completely independent of wake_zone.sh. On failure, the existing cache
file is left untouched, so a single missed discovery cycle doesn't take
down anything that's currently working.

Usage:
    discover.py [--config /path/to/config.conf]

Exit codes:
    0  discovery succeeded, cache updated
    1  discovery failed, cache left as-is (see stderr for details)
"""

import argparse
import os
import re
import socket
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900

ZONE_SERVICE_TYPE = "urn:schemas-nuvotechnologies-com:service:Zone:1"
AVTRANSPORT_SERVICE_TYPE = "urn:schemas-upnp-org:service:AVTransport:1"

DEFAULT_CONFIG_PATHS = ["./config.conf", "/etc/nuvo-zone-keepalive/config.conf"]


def load_config(path):
    """Very small shell-style KEY="VALUE" config file parser."""
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
            if not m:
                continue
            key, val = m.group(1), m.group(2).strip()
            val = val.strip('"').strip("'")
            cfg[key] = val
    return cfg


def find_config(explicit_path):
    if explicit_path:
        return explicit_path
    for p in DEFAULT_CONFIG_PATHS:
        if os.path.isfile(p):
            return p
    sys.exit("No config file found. Pass --config /path/to/config.conf "
              "or place one at " + " or ".join(DEFAULT_CONFIG_PATHS))


def ssdp_discover(member_mac, timeout):
    """Send an SSDP M-SEARCH and return LOCATION headers from replies whose
    body mentions our target member MAC."""
    msg = (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        "ST: ssdp:all\r\n"
        "\r\n"
    ).encode()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(timeout)
    sock.sendto(msg, (SSDP_ADDR, SSDP_PORT))

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


def get_control_urls(location):
    """Fetch the device description XML, return {serviceType: absolute control URL}."""
    with urllib.request.urlopen(location, timeout=5) as resp:
        xml_bytes = resp.read()

    root = ET.fromstring(xml_bytes)
    ns = {"d": "urn:schemas-upnp-org:device-1-0"}

    result = {}
    for service in root.findall(".//d:service", ns):
        stype = service.findtext("d:serviceType", default="", namespaces=ns)
        curl = service.findtext("d:controlURL", default="", namespaces=ns)
        if stype and curl:
            result[stype] = urljoin(location, curl)
    return result


def atomic_write(path, content):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp_path, path)  # atomic on POSIX
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=None)
    args = parser.parse_args()

    config_path = find_config(args.config)
    cfg = load_config(config_path)

    member_mac = cfg.get("NUVO_MEMBER_MAC")
    cache_file = cfg.get("NUVO_CACHE_FILE")
    timeout = float(cfg.get("NUVO_SSDP_TIMEOUT", "3"))

    if not member_mac or member_mac == "000000000000":
        sys.exit("NUVO_MEMBER_MAC is not set in " + config_path)
    if not cache_file:
        sys.exit("NUVO_CACHE_FILE is not set in " + config_path)

    locations = ssdp_discover(member_mac, timeout)
    if not locations:
        print(f"discover.py: no device found for MAC {member_mac} "
              f"(cache left untouched)", file=sys.stderr)
        sys.exit(1)

    location = sorted(locations)[0]

    try:
        control_urls = get_control_urls(location)
    except Exception as e:
        print(f"discover.py: failed to fetch/parse device description: {e} "
              f"(cache left untouched)", file=sys.stderr)
        sys.exit(1)

    zone_url = control_urls.get(ZONE_SERVICE_TYPE)
    av_url = control_urls.get(AVTRANSPORT_SERVICE_TYPE)

    if not zone_url or not av_url:
        print(f"discover.py: device description missing expected service "
              f"(zone={zone_url}, av={av_url}) (cache left untouched)",
              file=sys.stderr)
        sys.exit(1)

    content = (
        f'# auto-generated by discover.py at {time.strftime("%Y-%m-%d %H:%M:%S")}\n'
        f'ZONE_CONTROL_URL="{zone_url}"\n'
        f'AVTRANSPORT_CONTROL_URL="{av_url}"\n'
    )
    atomic_write(cache_file, content)
    print(f"discover.py: cache updated ({zone_url}, {av_url})")


if __name__ == "__main__":
    main()
