#!/bin/bash
# nuvo-zone-keepalive: tear_zone_down.sh
#
# OPTIONAL companion to wake_zone.sh. Disbands the group wake_zone.sh
# created, right away, instead of waiting for either the Nuvo's own idle
# timeout or the next wake_zone.sh run to clean it up. Intended for a
# shairport-sync `run_this_after_play_ends` hook.
#
# This is a tidiness improvement, not a fix for anything broken: even
# without it, wake_zone.sh already disbands the previous group before
# creating a new one, so at most one orphaned group ever exists at a
# time either way. Skip this script entirely if you don't care about
# the zone showing "active" in the app for a while after playback stops.
#
# On a successful disband, also clears the group-state file, so the
# next wake_zone.sh run doesn't waste a call re-disbanding a group that's
# already gone.
#
# Usage: tear_zone_down.sh [--config /path/to/config.conf]

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

EXPLICIT_CONFIG=""
if [[ "${1:-}" == "--config" ]]; then
    EXPLICIT_CONFIG="$2"
fi
nuvo_load_config_and_resolve_urls "$EXPLICIT_CONFIG"

echo "--- $(date) (tear_zone_down) ---" >> "$LOG"

if [[ ! -f "$GROUP_STATE_FILE" ]]; then
    echo "No group state file at $GROUP_STATE_FILE -- nothing to tear down." >> "$LOG"
    exit 0
fi

# shellcheck disable=SC1090
source "$GROUP_STATE_FILE"
if [[ -z "${LAST_GROUP_ID:-}" ]]; then
    echo "Group state file has no LAST_GROUP_ID -- nothing to tear down." >> "$LOG"
    exit 0
fi

DISBAND_RESPONSE=$(curl -s -X POST "$ZONE_CONTROL_URL" \
    -H 'SOAPAction: "urn:schemas-nuvotechnologies-com:service:Zone:1#GroupDisband"' \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GroupDisband xmlns:u=\"urn:schemas-nuvotechnologies-com:service:Zone:1\"><groupID>${LAST_GROUP_ID}</groupID></u:GroupDisband></s:Body></s:Envelope>")
echo "GroupDisband (groupID $LAST_GROUP_ID): $DISBAND_RESPONSE" >> "$LOG"

# Only clear the tracked groupID if the disband actually succeeded (no
# SOAP fault) -- if it failed for some reason, leave the file alone so
# wake_zone.sh still tries to clean it up next time, same as before this
# script existed.
if echo "$DISBAND_RESPONSE" | grep -q "s:Fault"; then
    echo "GroupDisband faulted; leaving $GROUP_STATE_FILE as-is for wake_zone.sh to retry later." >> "$LOG"
else
    rm -f "$GROUP_STATE_FILE"
    echo "Disband succeeded; cleared $GROUP_STATE_FILE." >> "$LOG"
fi
