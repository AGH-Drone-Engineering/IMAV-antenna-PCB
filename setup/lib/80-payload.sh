#!/usr/bin/env bash
# setup/lib/80-payload.sh — air-unit-only: enable the Pi's UART for MAVLink
# and make sure the kernel's serial console isn't fighting the flight
# controller for the same port. No-op on the gs role, and no-op if MAVLink
# is coming in over UDP instead of a UART (MAVLINK_UDP_PORT set).

stage_payload() {
    if [ "$ROLE" != "air" ]; then
        log "Role is gs -- nothing to do here (UART setup is air-only)."
        return 0
    fi
    if [ -n "$MAVLINK_UDP_PORT" ]; then
        log "MAVLINK_UDP_PORT is set -- MAVLink comes in over UDP, not a UART. Skipping serial setup."
        return 0
    fi

    local config_txt cmdline_txt
    if [ -f /boot/firmware/config.txt ]; then
        config_txt=/boot/firmware/config.txt
        cmdline_txt=/boot/firmware/cmdline.txt
    elif [ -f /boot/config.txt ]; then
        config_txt=/boot/config.txt
        cmdline_txt=/boot/cmdline.txt
    else
        warn "Neither /boot/firmware/config.txt nor /boot/config.txt found -- is this actually a Raspberry Pi OS image? Skipping UART setup; do it by hand if MAVLINK_SERIAL needs it."
        return 0
    fi

    _payload_enable_uart "$config_txt"
    _payload_remove_serial_console "$cmdline_txt"
}

_payload_enable_uart() {
    local f="$1"
    if grep -qE '^\s*enable_uart\s*=\s*1\s*$' "$f" 2>/dev/null; then
        log "enable_uart=1 already set in $f"
        return 0
    fi
    log "Adding enable_uart=1 to $f"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would append enable_uart=1 to $f"
        return 0
    fi
    backup_file "$f"
    printf '\n# Added by setup/lib/80-payload.sh -- MAVLink over %s\nenable_uart=1\n' "$MAVLINK_SERIAL" >> "$f"
}

# The Pi's default cmdline.txt puts a login console on the primary UART
# (console=serial0,115200 or console=ttyAMA0,115200 depending on model/OS
# version). That fights the flight controller for the port -- both ends
# transmitting on the same wire garbles MAVLink. Strip only that token,
# leave everything else on the single cmdline.txt line untouched.
_payload_remove_serial_console() {
    local f="$1"
    [ -f "$f" ] || { warn "$f not found -- skipping serial console removal."; return 0; }

    if ! grep -qE 'console=(serial0|ttyAMA0|ttyS0)' "$f"; then
        log "No serial console entry found in $f -- nothing to remove."
        return 0
    fi

    log "Removing serial console entry from $f"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would strip console=serial0/ttyAMA0/ttyS0,<baud> from $f"
        return 0
    fi
    backup_file "$f"
    sed -i -E 's/console=(serial0|ttyAMA0|ttyS0),[0-9]+ ?//g' "$f"
    # cmdline.txt must remain a single line with no trailing/leading junk.
    sed -i -E 's/  +/ /g; s/^ //; s/ $//' "$f"
}
