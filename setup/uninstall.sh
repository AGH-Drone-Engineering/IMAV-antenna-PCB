#!/usr/bin/env bash
# setup/uninstall.sh — reverse what install.sh did: stop services, remove
# the DKMS driver, purge wfb-ng, and remove the config files we placed.
# Does NOT touch /etc/drone.key or /etc/gs.key, and does NOT restore
# /boot/firmware/config.txt or cmdline.txt automatically -- those are backed
# up (see the .bak.<timestamp> files install.sh left next to them) but
# restoring boot config automatically is exactly the kind of thing that
# should require a human to look at the diff first.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

ASSUME_YES=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./uninstall.sh [--yes] [--dry-run]

Stops wifibroadcast@drone/@gs and the video services (wfb-video-air,
rtsp@h264/h265), removes the DKMS driver, purges the wfb-ng apt package, and
removes the modprobe.d/NetworkManager/video files this installer placed.
Leaves /etc/drone.key, /etc/gs.key, and boot config files alone
(config.txt/cmdline.txt changes are left in place; their .bak.* backups are
next to them if you want to diff and restore manually).
EOF
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

need_root
[ -f "$HERE/VERSIONS" ] && source "$HERE/VERSIONS"

warn "This will stop wfb-ng services, remove the DKMS driver, and purge the wfb-ng package."
confirm_or_die "Proceed?"

log "Stopping services"
# No `2>/dev/null` on these: it would redirect the WHOLE `run ...` command's
# stderr, including run()'s own transcript line (which is written to stderr
# by design -- see lib/common.sh), not just systemctl's "unit not loaded"
# noise. Verified empirically: that redirect silently ate every one of these
# transcript lines, in both dry-run and real runs. `|| true` alone is enough
# to keep going past a service that was never installed; a stray "unit not
# found" from systemctl on stderr is informative, not noise worth hiding.
run systemctl disable --now wifibroadcast@drone || true
run systemctl disable --now wifibroadcast@gs || true
run systemctl disable --now wfb-video-air.service || true
run systemctl disable --now rtsp@h264.service || true
run systemctl disable --now rtsp@h265.service || true
run rm -f /etc/systemd/system/wfb-video-air.service
run rm -f /usr/local/bin/wfb-video-air

log "Removing DKMS driver"
if command -v dkms >/dev/null 2>&1; then
    # The trailing `|| true` matters: under `set -e -o pipefail`, this whole
    # pipeline's exit status is non-zero whenever there's simply nothing to
    # remove (grep matches nothing, and/or the while/read loop hits EOF with
    # zero iterations) -- which is the NORMAL case on a host where the
    # driver was never installed or was already removed. Without the guard,
    # that ordinary case would abort the script here, before it reaches the
    # apt purge and config cleanup below.
    dkms status 2>/dev/null | grep -i 'rtl88x2eu\|realtek-rtl88x2eu' | cut -d, -f1 | while read -r mod; do
        run dkms remove "$mod" --all || true
    done || true
fi
run rm -rf /usr/src/wfb-driver-src
run rm -rf /usr/src/realtek-rtl88x2eu-*

log "Purging wfb-ng"
if command -v apt-mark >/dev/null 2>&1; then
    run apt-mark unhold wfb-ng || true
fi
run apt-get purge -y wfb-ng || true
run rm -f /etc/apt/sources.list.d/wfb-ng.list /usr/share/keyrings/wfb-ng.gpg

log "Removing config files placed by install.sh"
run rm -f /etc/modprobe.d/10-wfb-rtl88x2eu.conf
run rm -f /etc/NetworkManager/conf.d/99-wfb-unmanaged.conf
run rm -f /etc/wifibroadcast.cfg

log "Done. NOT removed (on purpose): /etc/drone.key, /etc/gs.key, boot config changes."
log "Their .bak.<timestamp> files are next to the originals if you want those back too."
