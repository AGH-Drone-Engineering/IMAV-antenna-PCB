#!/usr/bin/env bash
# setup/lib/40-wfb-ng.sh — install wfb-ng itself from apt.wfb-ng.org, pinned
# and held. Ships wifibroadcast@.service, wfb-cli, wfb-nics, rtsp@.service,
# /etc/default/wifibroadcast -- we do not reimplement any of those.
#
# On Trixie, the 'release-25.01' component's package index is EMPTY on every
# architecture (verified: zero-byte Packages file). 'master' -- a rolling
# snapshot -- is the only channel that works there at all. That's exactly
# why VERSIONS pins an exact version and this stage apt-mark holds it: you
# are deliberately riding a moving target, so both ends must match exactly.

WFB_KEYRING=/usr/share/keyrings/wfb-ng.gpg
WFB_LIST=/etc/apt/sources.list.d/wfb-ng.list

stage_wfb_ng() {
    _wfb_ng_add_repo
    run apt-get update -qq

    log "Installing wfb-ng=${WFB_VERSION} (component: ${WFB_APT_COMPONENT})"
    if ! run apt-get install -y "wfb-ng=${WFB_VERSION}"; then
        die "apt install wfb-ng=${WFB_VERSION} failed. Either the pinned version" \
            "aged out of the ${WFB_APT_COMPONENT} component's window, or the" \
            "codename '${CODENAME}' isn't what VERSIONS expects. Check:" \
            "  apt-cache madison wfb-ng" \
            "and update WFB_VERSION in setup/VERSIONS on BOTH ends to match."
    fi
    run apt-mark hold wfb-ng

    _wfb_ng_verify_tun_binary
}

_wfb_ng_add_repo() {
    if [ -f "$WFB_KEYRING" ] && [ -f "$WFB_LIST" ]; then
        log "wfb-ng apt repo already configured"
        return 0
    fi
    log "Adding apt.wfb-ng.org repository (component: ${WFB_APT_COMPONENT})"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would fetch https://apt.wfb-ng.org/public.asc -> $WFB_KEYRING"
        log "[dry-run] would write $WFB_LIST"
        return 0
    fi
    curl -fsSL https://apt.wfb-ng.org/public.asc | gpg --dearmor --yes -o "$WFB_KEYRING"
    echo "deb [signed-by=${WFB_KEYRING}] https://apt.wfb-ng.org/ ${CODENAME} ${WFB_APT_COMPONENT}" > "$WFB_LIST"
    log "Wrote $WFB_LIST"
}

# The wfb_tun binary is built by the driver's Makefile but is (as of this
# writing) absent from wfb-ng's own setup.py data_files list -- meaning it is
# NOT GUARANTEED to be part of the .deb. Without it there is no IP tunnel,
# and without the tunnel there is no SSH in this MVP. Check for it explicitly
# rather than discovering the gap later as "why doesn't ssh work".
_wfb_ng_verify_tun_binary() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would verify wfb_tun is installed by the package"
        return 0
    fi
    if dpkg -L wfb-ng 2>/dev/null | grep -q 'wfb_tun$'; then
        log "wfb_tun present (tunnel/SSH path is available)"
    else
        warn "wfb_tun was NOT found in the wfb-ng package file list."
        warn "This means the IP tunnel (and therefore SSH over the link) will"
        warn "NOT come up, even though everything else in this installer succeeds."
        warn "See docs/troubleshooting.md for building/installing wfb_tun manually."
    fi
}
