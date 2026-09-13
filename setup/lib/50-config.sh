#!/usr/bin/env bash
# setup/lib/50-config.sh — validate link.conf values, render the config
# templates, and write /etc/wifibroadcast.cfg. Validation happens BEFORE any
# file is written: a bad value caught here is a one-line error message; the
# same bad value caught later is "the link doesn't come up" with nothing
# useful in the logs.

WFB_CFG_COMMON_TPL="$HERE/config/wifibroadcast.common.cfg.in"
WFB_CFG_ROLE_TPL_AIR="$HERE/config/wifibroadcast.air.cfg.in"
WFB_CFG_ROLE_TPL_GS="$HERE/config/wifibroadcast.gs.cfg.in"
WFB_CFG_OUT=/etc/wifibroadcast.cfg

stage_config() {
    _config_validate
    _config_compute_derived

    local role_tpl
    [ "$ROLE" = "air" ] && role_tpl="$WFB_CFG_ROLE_TPL_AIR" || role_tpl="$WFB_CFG_ROLE_TPL_GS"

    # NOTE: deliberately NOT using `trap ... RETURN` for cleanup here. In
    # bash, a RETURN trap set inside a function is NOT scoped to that call --
    # it stays armed and fires again on the *next* function/sourced-script
    # return anywhere later in the script, by which point tmp_common/tmp_role
    # (local to this call frame) no longer exist, and `set -u` turns that
    # into an "unbound variable" crash in a completely unrelated later stage.
    # Explicit cleanup at every exit point instead.
    local tmp_common tmp_role
    tmp_common="$(mktemp)"; tmp_role="$(mktemp)"

    local common_vars='$WIFI_CHANNEL $WIFI_REGION $WIFI_TXPOWER $BANDWIDTH $MCS_INDEX $STBC $LDPC $SHORT_GI $MAVLINK_SYS_ID $FEC_MAVLINK_K $FEC_MAVLINK_N $FEC_MAVLINK_TIMEOUT $FEC_TUNNEL_K $FEC_TUNNEL_N $FEC_TUNNEL_TIMEOUT $FEC_VIDEO_K $FEC_VIDEO_N'
    render_template "$WFB_CFG_COMMON_TPL" "$tmp_common" "$common_vars"

    if [ "$ROLE" = "air" ]; then
        local role_vars='$LINK_DOMAIN $AIR_MAVLINK_PEER $TUNNEL_IP_AIR $TUNNEL_PREFIX'
    else
        local role_vars='$LINK_DOMAIN $QGC_HOST $QGC_PORT $TUNNEL_IP_GS $TUNNEL_PREFIX'
    fi
    render_template "$role_tpl" "$tmp_role" "$role_vars"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would write $WFB_CFG_OUT from $WFB_CFG_COMMON_TPL + $role_tpl"
        rm -f "$tmp_common" "$tmp_role"
        return 0
    fi

    backup_file "$WFB_CFG_OUT"
    {
        echo "# Concatenated by setup/lib/50-config.sh -- see setup/link.conf, not this file."
        cat "$tmp_common"
        echo
        cat "$tmp_role"
    } > "$WFB_CFG_OUT"
    log "Wrote $WFB_CFG_OUT"

    log "Effective radio-section fingerprint (compare this to the peer -- must match): $(sha256_short "$tmp_common")"
    rm -f "$tmp_common" "$tmp_role"
}

_config_validate() {
    case "$BANDWIDTH" in
        10|20) ;;
        5) die "BANDWIDTH=5 will crash wfb_tx (unsupported HT bandwidth). Use 10 or 20." ;;
        40) die "BANDWIDTH=40 is rejected: this chipset has a known firmware injection bug at 40MHz. Use 10 or 20." ;;
        *) die "BANDWIDTH must be 10 or 20 (got '$BANDWIDTH')." ;;
    esac

    case "$MCS_INDEX" in
        0|1|2|3|4|5|6|7) ;;
        *) die "MCS_INDEX must be 0-7 (got '$MCS_INDEX')." ;;
    esac

    case "$WIFI_CHANNEL" in
        ''|*[!0-9]*) die "WIFI_CHANNEL must be a plain number (channel or MHz frequency), got '$WIFI_CHANNEL'." ;;
    esac

    case "$LDPC" in
        0|1) ;;
        *) die "LDPC must be 0 or 1 (got '$LDPC'). This driver documents LDPC as 8812au-only; 0 is the safe default." ;;
    esac

    case "$STBC" in
        0|1) ;;
        2|3) warn "STBC=$STBC is accepted by wfb_tx without error, but a 2T2R card like this one only has the TX chains for STBC=1. Values 2/3 are unverified on this hardware -- expect this to silently misbehave rather than fail loudly." ;;
        *) die "STBC must be 0-3 (got '$STBC')." ;;
    esac

    case "$SHORT_GI" in
        True|False) ;;
        *) die "SHORT_GI must be True or False (Python literal, capitalized) -- got '$SHORT_GI'." ;;
    esac

    case "$POWER_SOURCE" in
        usb-pi|hub|external) ;;
        *) die "POWER_SOURCE must be usb-pi, hub, or external (got '$POWER_SOURCE')." ;;
    esac

    case "$WIFI_TXPOWER" in
        ''|*[!0-9]*) die "WIFI_TXPOWER must be a plain non-negative integer (dBm*100 for 8812eu), got '$WIFI_TXPOWER'." ;;
    esac
    if [ "$WIFI_TXPOWER" -gt 3150 ]; then
        die "WIFI_TXPOWER=$WIFI_TXPOWER exceeds the driver's hard maximum of 3150."
    fi
    local ceiling
    if [ "$POWER_SOURCE" = "usb-pi" ]; then
        ceiling="$TXPOWER_MAX_USB"
    else
        ceiling="$TXPOWER_MAX_EXTERNAL"
    fi
    if [ "$WIFI_TXPOWER" -gt "$ceiling" ]; then
        if [ "$IWKWID" = "1" ]; then
            warn "WIFI_TXPOWER=$WIFI_TXPOWER exceeds the $POWER_SOURCE ceiling ($ceiling) -- proceeding because --i-know-what-im-doing was given."
        else
            die "WIFI_TXPOWER=$WIFI_TXPOWER exceeds the ceiling for POWER_SOURCE=$POWER_SOURCE ($ceiling)." \
                "Both antennas must be fitted and, if POWER_SOURCE=usb-pi, this is well" \
                "above what a Pi USB port can reliably supply. Lower WIFI_TXPOWER, set" \
                "POWER_SOURCE=external if genuinely powered from the carrier board's" \
                "battery/BEC leads, or pass --i-know-what-im-doing to override."
        fi
    fi

    if [ -z "$MAVLINK_UDP_PORT" ]; then
        # Serial mode: wfb-ng's own regex is ^serial:[a-z0-9_/-]+:[0-9]+$
        # (case-insensitive) -- '.' and ':' inside the device path are the
        # real trap (e.g. /dev/serial/by-id/... contains both).
        case "$MAVLINK_SERIAL" in
            *[!a-zA-Z0-9_/-]*)
                die "MAVLINK_SERIAL='$MAVLINK_SERIAL' contains a character wfb-ng's serial: transport rejects (only letters, digits, '_', '/', '-' are allowed -- notably no '.' or ':'). Use a short udev symlink instead of a by-id path, or set MAVLINK_UDP_PORT instead."
                ;;
        esac
        case "$MAVLINK_BAUD" in
            ''|*[!0-9]*) die "MAVLINK_BAUD must be numeric (got '$MAVLINK_BAUD')." ;;
        esac
    else
        case "$MAVLINK_UDP_PORT" in
            ''|*[!0-9]*) die "MAVLINK_UDP_PORT must be numeric (got '$MAVLINK_UDP_PORT')." ;;
        esac
    fi
}

_config_compute_derived() {
    # AIR_MAVLINK_PEER only ends up used in the air-side template, but it's
    # computed here regardless of $ROLE (harmless either way) -- only LOG it
    # on the air role, though, so a gs-role run doesn't print a misleading
    # "air unit will..." line about a value it isn't actually acting on.
    if [ -n "$MAVLINK_UDP_PORT" ]; then
        AIR_MAVLINK_PEER="listen://0.0.0.0:${MAVLINK_UDP_PORT}"
        [ "$ROLE" = "air" ] && log "MAVLink: air unit will LISTEN for UDP on port $MAVLINK_UDP_PORT (MAVLINK_SERIAL ignored)"
    else
        AIR_MAVLINK_PEER="serial:${MAVLINK_SERIAL}:${MAVLINK_BAUD}"
        [ "$ROLE" = "air" ] && log "MAVLink: air unit will open $MAVLINK_SERIAL @ $MAVLINK_BAUD baud"
    fi
    export AIR_MAVLINK_PEER
}
