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

# wfb_tun is built by wfb-ng's OWN Makefile (all_bin target) but is -- as
# confirmed against the real package on real hardware, not just read in
# source -- absent from wfb-ng's setup.py data_files list, so the .deb does
# not ship it. Without it there is no IP tunnel, and without the tunnel
# there is no SSH in this MVP. Rather than just warning and leaving it as a
# manual troubleshooting step, build and install it ourselves: it's a small,
# dependency-light binary (libevent only) with a stable local IPC protocol,
# and SSH is core MVP scope, not an optional extra.
TUN_SRC_DIR="/usr/src/wfb-ng-tun-src"

_wfb_ng_verify_tun_binary() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would verify wfb_tun is installed by the package, and build it ourselves if not"
        return 0
    fi
    if dpkg -L wfb-ng 2>/dev/null | grep -q 'wfb_tun$'; then
        log "wfb_tun present (tunnel/SSH path is available)"
        return 0
    fi
    if command -v wfb_tun >/dev/null 2>&1; then
        log "wfb_tun not in the package, but already built and installed at $(command -v wfb_tun) -- skipping rebuild"
        return 0
    fi

    warn "wfb_tun was NOT found in the wfb-ng package file list (confirmed: this is a"
    warn "real gap in the .deb, not a guess). Building it from source instead --"
    warn "SSH over the tunnel needs it."
    _wfb_ng_build_tun
}

# Build wfb_tun from the EXACT commit the installed package itself was built
# from (not just "whatever is on master right now"), so the binary can never
# silently drift from the installed wfb-ng version -- including on a host
# where VERSIONS pins an older/different snapshot than "current master".
# That commit is recorded by wfb-ng's own build process in site.cfg, which
# is why we read it from there instead of assuming anything.
_wfb_ng_build_tun() {
    local site_cfg commit
    site_cfg="$(dpkg -L wfb-ng 2>/dev/null | grep 'conf/site\.cfg$' | head -1)"
    [ -n "$site_cfg" ] && [ -f "$site_cfg" ] || die "Could not locate wfb-ng's site.cfg to determine its exact build commit. Build wfb_tun manually -- see docs/troubleshooting.md."
    commit="$(grep -E "^commit = " "$site_cfg" | sed -E "s/^commit = '([0-9a-f]+)'/\1/")"
    [ -n "$commit" ] || die "Could not read the build commit out of $site_cfg."
    log "Installed wfb-ng was built from commit $commit -- building wfb_tun from the same commit"

    run apt-get install -y libevent-dev

    if [ -d "$TUN_SRC_DIR/.git" ]; then
        run git -C "$TUN_SRC_DIR" fetch --depth 1 origin "$commit"
    else
        run git clone https://github.com/svpcom/wfb-ng.git "$TUN_SRC_DIR"
        run git -C "$TUN_SRC_DIR" fetch --depth 1 origin "$commit"
    fi
    run git -C "$TUN_SRC_DIR" checkout --detach FETCH_HEAD

    log "Building wfb_tun"
    ( cd "$TUN_SRC_DIR" && run make wfb_tun ) || die "Building wfb_tun from source failed. See docs/troubleshooting.md."

    install_file "$TUN_SRC_DIR/wfb_tun" /usr/bin/wfb_tun 0755
    log "wfb_tun built and installed: $(/usr/bin/wfb_tun --help 2>&1 | grep -o 'WFB-ng version.*')"
}
