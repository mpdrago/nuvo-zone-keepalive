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
# See also: tear_zone_down.sh, an optional companion for the reverse
# action (run_this_after_play_ends).
#
# Usage: wake_zone.sh [--config /path/to/config.conf]

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

EXPLICIT_CONFIG=""
if [[ "${1:-}" == "--config" ]]; then
    EXPLICIT_CONFIG="$2"
fi
nuvo_load_config_and_resolve_urls "$EXPLICIT_CONFIG"

echo "--- $(date) ---" >> "$LOG"

if [[ -z "${NUVO_MEMBER_MAC:-}" || "$NUVO_MEMBER_MAC" == "000000000000" ]]; then
    echo "NUVO_MEMBER_MAC not set in $CONFIG_PATH" | tee -a "$LOG" >&2
    exit 1
fi

echo "Using ZONE_CONTROL_URL=$ZONE_CONTROL_URL AVTRANSPORT_CONTROL_URL=$AVTRANSPORT_CONTROL_URL" >> "$LOG"

# --- 0) Check whether we're already in the group we last created ---
# Active/PowerState in Get's response don't tell us this (both read
# "active" regardless of grouping, confirmed by testing) -- the current
# MemberGroup id is what actually distinguishes "still grouped" from
# "idled out". If it matches what we tracked last time, the zone never
# actually went idle (e.g. a quick stop/restart) and there's no need to
# disband+recreate -- we just skip straight to (re-)asserting the source
# below, avoiding an unnecessary group churn/reconnect blip on the Nuvo.
SKIP_GROUP_RECREATE="no"
if [[ -f "$GROUP_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$GROUP_STATE_FILE"
    if [[ -n "${LAST_GROUP_ID:-}" ]]; then
        CURRENT_GROUP_ID=$(nuvo_get_current_group_id "$ZONE_CONTROL_URL")
        echo "Current MemberGroup id: '${CURRENT_GROUP_ID}' (tracked: '${LAST_GROUP_ID}')" >> "$LOG"
        if [[ -n "$CURRENT_GROUP_ID" && "$CURRENT_GROUP_ID" == "$LAST_GROUP_ID" ]]; then
            SKIP_GROUP_RECREATE="yes"
            echo "Zone is still in the tracked group; skipping disband+recreate." >> "$LOG"
        fi
    fi
fi

if [[ "$SKIP_GROUP_RECREATE" == "no" ]]; then
    # --- 0a) Disband the previous group we created, if we're tracking one ---
    # GroupCreate mints a brand-new group every call and never cleans up
    # after itself, so without this, calling it repeatedly (e.g. every
    # playback start) leaves an ever-growing pile of orphaned groups on the
    # Nuvo. Best-effort: if the old group is already gone for any reason
    # (e.g. already cleaned up by tear_zone_down.sh, or the check above
    # just told us it's gone), GroupDisband will just fault, which we log
    # and ignore rather than treating as fatal.
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

    # --- 0b) Create/rejoin the group (this is what "drag zone into start" does) ---
    GROUP_RESPONSE=$(curl -s -X POST "$ZONE_CONTROL_URL" \
        -H 'SOAPAction: "urn:schemas-nuvotechnologies-com:service:Zone:1#GroupCreate"' \
        -H 'Content-Type: text/xml; charset="utf-8"' \
        --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GroupCreate xmlns:u=\"urn:schemas-nuvotechnologies-com:service:Zone:1\"><memberIDs>[\"memberId-${NUVO_MEMBER_MAC}\"]</memberIDs></u:GroupCreate></s:Body></s:Envelope>")
    echo "GroupCreate: $GROUP_RESPONSE" >> "$LOG"

    # Persist the new groupID (atomically) so next run (or tear_zone_down.sh)
    # can disband it.
    NEW_GROUP_ID=$(echo "$GROUP_RESPONSE" | sed -n 's/.*<groupID>\([^<]*\)<\/groupID>.*/\1/p')
    if [[ -n "$NEW_GROUP_ID" ]]; then
        TMP_STATE_FILE=$(mktemp "${GROUP_STATE_FILE}.XXXXXX")
        echo "LAST_GROUP_ID=\"${NEW_GROUP_ID}\"" > "$TMP_STATE_FILE"
        mv -f "$TMP_STATE_FILE" "$GROUP_STATE_FILE"
        echo "Saved new groupID: $NEW_GROUP_ID" >> "$LOG"
    else
        echo "Could not parse a groupID out of the GroupCreate response; not updating state file." >> "$LOG"
    fi
fi

# --- 1) Select Line In as the zone's source ---
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
