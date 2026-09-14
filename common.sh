#!/bin/bash
# nuvo-zone-keepalive: common.sh
#
# Shared by wake_zone.sh and tear_zone_down.sh: finds/loads config.conf and
# resolves the current Zone/AVTransport control URLs (static or from the
# discovery cache). Not meant to be run directly -- source it.
#
# Expects SCRIPT_DIR to already be set by the caller. Sets CONFIG_PATH,
# LOG, GROUP_STATE_FILE, ZONE_CONTROL_URL, and AVTRANSPORT_CONTROL_URL,
# and exits with an error (printed to the given $LOG once it's known) if
# anything required is missing.

nuvo_find_config() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    if [[ -f "${SCRIPT_DIR}/config.conf" ]]; then
        echo "${SCRIPT_DIR}/config.conf"
    elif [[ -f "/etc/nuvo-zone-keepalive/config.conf" ]]; then
        echo "/etc/nuvo-zone-keepalive/config.conf"
    fi
}

nuvo_get_current_group_id() {
    # Calls the Zone service's Get action and returns the zone's current
    # MemberGroup id -- empty string if the zone isn't currently in a
    # group. NOTE: Active/PowerState in the Get response do NOT indicate
    # this (both read "1"/"active" whether grouped or not, confirmed by
    # testing); the MemberGroup field's embedded id is what actually
    # distinguishes the two states. Echoes empty string (not an error) if
    # the call fails, so callers can safely fall back to the old
    # disband-then-create behavior.
    local zone_control_url="$1"

    local response
    response=$(curl -s -X POST "$zone_control_url" \
        -H 'SOAPAction: "urn:schemas-nuvotechnologies-com:service:Zone:1#Get"' \
        -H 'Content-Type: text/xml; charset="utf-8"' \
        --data '<?xml version="1.0" encoding="UTF-8"?><s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Get xmlns:u="urn:schemas-nuvotechnologies-com:service:Zone:1"></u:Get></s:Body></s:Envelope>' \
        2>/dev/null)

    echo "$response" | sed -n 's/.*<MemberGroup>{&quot;id&quot;:&quot;\([^&]*\)&quot;.*/\1/p'
}

nuvo_load_config_and_resolve_urls() {
    local explicit_config="$1"

    CONFIG_PATH="$(nuvo_find_config "$explicit_config")"
    if [[ -z "$CONFIG_PATH" ]]; then
        echo "No config.conf found. Copy config.example.conf to config.conf and edit it." >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_PATH"

    LOG="${NUVO_LOG_FILE:-${SCRIPT_DIR}/wake_zone.log}"
    GROUP_STATE_FILE="${NUVO_GROUP_STATE_FILE:-${SCRIPT_DIR}/last-group-id.conf}"

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
}
