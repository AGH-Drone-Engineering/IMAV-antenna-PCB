#!/usr/bin/env bash
# setup/lib/70-services.sh — enable and start the wfb-ng systemd instance for
# this role. The unit itself (wifibroadcast@.service), /etc/default/wifibroadcast
# (which autodetects the card via `wfb-nics`, matching by driver name so it
# doesn't care whether the kernel calls it wlan0/wlan1/wlx...), wfb-cli and
# wfb-nics all come from the wfb-ng package -- nothing to install here.
#
# The package's postinst only runs `systemctl daemon-reload`; it does NOT
# enable any service, so that's on us.

stage_services() {
    local profile
    [ "$ROLE" = "air" ] && profile="drone" || profile="gs"

    log "Enabling and starting wifibroadcast@${profile}"
    run systemctl daemon-reload
    # `|| true` matters: `systemctl enable --now` can itself return non-zero
    # when the unit fails to activate (e.g. no wfb-capable NIC found yet --
    # confirmed on real hardware: wfb-server exits 2 immediately if wfb-nics
    # returns nothing, and --now surfaces that as enable's own exit code).
    # Under `set -e`, an unguarded failure here would abort the script
    # BEFORE reaching the diagnostic check below -- exactly the case that
    # check exists to handle. Let it fail, then diagnose properly.
    run systemctl enable --now "wifibroadcast@${profile}" || true

    if [ "${DRY_RUN:-0}" = "1" ]; then
        return 0
    fi

    sleep 2
    if systemctl is-active --quiet "wifibroadcast@${profile}"; then
        log "wifibroadcast@${profile} is active."
    else
        warn "wifibroadcast@${profile} did not come up cleanly. Check:"
        warn "    journalctl -u wifibroadcast@${profile} -e --no-pager"
        warn "Common causes: card not in monitor mode yet (needs 30-driver to have"
        warn "succeeded and the module actually plugged in), or a config syntax error"
        warn "from 50-config.sh (check /etc/wifibroadcast.cfg by hand)."
    fi

    log "Check link stats with: wfb-cli ${profile}"
}
