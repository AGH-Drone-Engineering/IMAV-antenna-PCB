#!/usr/bin/env bash
# setup/lib/detect.sh — platform detection. Sourced by install.sh before any
# stage runs; every stage after this can rely on PLATFORM/CODENAME/ARCH/KVER
# being set correctly, or the script having already died with a clear reason.
#
# Gates on facts (device-tree model, dpkg architecture, os-release), never on
# guesses -- an unsupported host should fail loudly here, not three stages in
# with a confusing apt or dkms error.

detect_platform() {
    [ -r /etc/os-release ] || die "No /etc/os-release -- this doesn't look like a Debian-family host."
    # shellcheck source=/dev/null
    . /etc/os-release

    CODENAME="${VERSION_CODENAME:-unknown}"
    ARCH="$(dpkg --print-architecture 2>/dev/null)" || die "dpkg not found -- this installer targets Debian/Ubuntu/Raspberry Pi OS."
    KVER="$(uname -r)"

    case "${ID:-}/${ID_LIKE:-}" in
        *debian*|debian/*|*/*debian*) ;;
        *) die "Unsupported distro: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}. This installer targets Debian/Ubuntu/Raspberry Pi OS." ;;
    esac

    PI_MODEL=""
    if [ -f /proc/device-tree/model ] && grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
        PI_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
        if [ "$ARCH" != "arm64" ]; then
            die "Raspberry Pi detected ($PI_MODEL) but dpkg arch is '$ARCH', not arm64. Use a 64-bit Raspberry Pi OS image."
        fi
        PLATFORM="rpi-arm64"
    elif [ "$ARCH" = "amd64" ]; then
        PLATFORM="debian-amd64"
    elif [ "$ARCH" = "arm64" ]; then
        # A non-Pi arm64 board (generic SBC). Treat like rpi-arm64 for driver
        # purposes (same Makefile platform flag) but flag it clearly.
        PLATFORM="rpi-arm64"
        warn "arm64 host without a Raspberry Pi device-tree model -- proceeding as a generic arm64 board. Kernel headers and DKMS behavior are unverified on non-Pi arm64."
    else
        die "Unsupported architecture '$ARCH' on $ID $CODENAME. Supported: Raspberry Pi OS arm64, Debian/Ubuntu amd64."
    fi

    case "$CODENAME" in
        bookworm|trixie|noble|jammy) ;;
        *) warn "Untested distro codename '$CODENAME' -- proceeding anyway, but see VERSIONS and docs/troubleshooting.md if the driver fails to build." ;;
    esac

    log "platform=$PLATFORM codename=$CODENAME arch=$ARCH kernel=$KVER${PI_MODEL:+ model=\"$PI_MODEL\"}"
}
