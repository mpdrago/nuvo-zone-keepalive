#!/bin/bash
# nuvo-zone-keepalive: wake_zone.sh
#
# Reactivates a Nuvo zone and selects Line In as its source, replicating
# the "drag zone into start" action from the official Nuvo Player app.
# Intended to be run right before playback begins (e.g. as a shairport-sync
# `run_this_before_play_begins` hook) so the zone is always ready.
#
# Reads its target (member MAC, zone name) and connection info (static
# host, or a cache file kept fresh by discover.py) from config.conf.
#
# Usage: wake_zone.sh [--config /path/to/config.conf]

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_PATH=""
if [[ "${1:-}" == "--config" ]]; then
    CONFIG_PATH="$2"
fi
if [[ -z "$CONFIG_PATH" ]]; then
    if [[ -f "${SCRIPT_DIR}/config.conf" ]]; then
        CONFIG_PATH="${SCRIPT_DIR}/config.conf"
    elif [[ -f "/etc/nuvo-zone-keepalive/config.conf" ]]; then
        CONFIG_PATH="/etc/nuvo-zone-keepalive/config.conf"
    else
        echo "No config.conf found. Copy config.example.conf to config.conf and edit it." >&2
        exit 1
    fi
fi

# shellcheck disable=SC1090
source "$CONFIG_PATH"

LOG="${NUVO_LOG_FILE:-${SCRIPT_DIR}/wake_zone.log}"
echo "--- $(date) ---" >> "$LOG"

if [[ -z "${NUVO_MEMBER_MAC:-}" || "$NUVO_MEMBER_MAC" == "000000000000" ]]; then
    echo "NUVO_MEMBER_MAC not set in $CONFIG_PATH" | tee -a "$LOG" >&2
    exit 1
fi

# --- Resolve control URLs, either statically or from the discovery cache ---
if [[ "${NUVO_DISCOVERY_MODE:-ssdp}" == "static" ]]; then
    ZONE_CONTROL_URL="http://${NUVO_STATIC_HOST}${NUVO_STATIC_ZONE_CONTROL_PATH}"
    AVTRANSPORT_CONTROL_URL="http://${NUVO_STATIC_HOST}${NUVO_STATIC_AVTRANSPORT_CONTROL_PATH}"
else
    if [[ ! -f "${NUVO_CACHE_FILE:-}" ]]; then
        echo "Discovery cache not found at ${NUVO_CACHE_FILE:-<unset>}. Is discover.py running?" | tee -a "$LOG" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$NUVO_CACHE_FILE"
    if [[ -z "${ZONE_CONTROL_URL:-}" || -z "${AVTRANSPORT_CONTROL_URL:-}" ]]; then
        echo "Discovery cache at $NUVO_CACHE_FILE is incomplete." | tee -a "$LOG" >&2
        exit 1
    fi
fi

echo "Using ZONE_CONTROL_URL=$ZONE_CONTROL_URL AVTRANSPORT_CONTROL_URL=$AVTRANSPORT_CONTROL_URL" >> "$LOG"

# --- 0) Disband the previous group we created, if we're tracking one ---
# GroupCreate mints a brand-new group every call and never cleans up after
# itself, so without this, calling it repeatedly (e.g. every playback start)
# leaves an ever-growing pile of orphaned groups on the Nuvo. We persist the
# groupID from our last successful GroupCreate and disband it before making
# a new one. Best-effort: if the old group is already gone (e.g. the zone
# was manually torn down since), GroupDisband will just fault, which we log
# and ignore rather than treating as fatal.
GROUP_STATE_FILE="${NUVO_GROUP_STATE_FILE:-${SCRIPT_DIR}/last-group-id.conf}"
if [[ -f "$GROUP_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$GROUP_STATE_FILE"
    if [[ -n "${LAST_GROUP_ID:-}" ]]; then
        DISBAND_RESPONSE=$(curl -s -X POST "$ZONE_CONTROL_URL" \
            -H 'SOAPAction: "urn:schemas-nuvotechnologies-com:service:Zone:1#GroupDisband"' \
            -H 'Content-Type: text/xml; charset="utf-8"' \
            --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GroupDisband xmlns:u=\"urn:schemas-nuvotechnologies-com:service:Zone:1\"><groupID>${LAST_GROUP_ID}</groupID></u:GroupDisband></s:Body></s:Envelope>")
        echo "GroupDisband (previous groupID $LAST_GROUP_ID): $DISBAND_RESPONSE" >> "$LOG"
    fi
fi

# --- 1) Create/rejoin the group (this is what "drag zone into start" does) ---
GROUP_RESPONSE=$(curl -s -X POST "$ZONE_CONTROL_URL" \
    -H 'SOAPAction: "urn:schemas-nuvotechnologies-com:service:Zone:1#GroupCreate"' \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GroupCreate xmlns:u=\"urn:schemas-nuvotechnologies-com:service:Zone:1\"><memberIDs>[\"memberId-${NUVO_MEMBER_MAC}\"]</memberIDs></u:GroupCreate></s:Body></s:Envelope>")
echo "GroupCreate: $GROUP_RESPONSE" >> "$LOG"

# Persist the new groupID (atomically) so next run can disband it first.
NEW_GROUP_ID=$(echo "$GROUP_RESPONSE" | sed -n 's/.*<groupID>\([^<]*\)<\/groupID>.*/\1/p')
if [[ -n "$NEW_GROUP_ID" ]]; then
    TMP_STATE_FILE=$(mktemp "${GROUP_STATE_FILE}.XXXXXX")
    echo "LAST_GROUP_ID=\"${NEW_GROUP_ID}\"" > "$TMP_STATE_FILE"
    mv -f "$TMP_STATE_FILE" "$GROUP_STATE_FILE"
    echo "Saved new groupID: $NEW_GROUP_ID" >> "$LOG"
else
    echo "Could not parse a groupID out of the GroupCreate response; not updating state file." >> "$LOG"
fi

# --- 2) Select Line In as the zone's source ---
# Body is templated from a byte-exact capture of the official app's request;
# only the member MAC and cosmetic zone name are substituted per-install.
BODY=$(sed -e "s/__MEMBER_MAC__/${NUVO_MEMBER_MAC}/g" \
           -e "s/__ZONE_NAME__/${NUVO_ZONE_NAME:-Zone}/g" \
           "${SCRIPT_DIR}/lineIn-body-template.xml")

SOURCE_RESPONSE=$(curl -s -X POST "$AVTRANSPORT_CONTROL_URL" \
    -H 'SOAPAction: "urn:schemas-upnp-org:service:AVTransport:1#X_NUVO_PlayContainerURI"' \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    --data-binary "$BODY")
echo "PlayContainerURI: $SOURCE_RESPONSE" >> "$LOG"
