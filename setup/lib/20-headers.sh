#!/usr/bin/env bash
# setup/lib/20-headers.sh — kernel headers, with a fallback chain per platform
# because the exact package name varies (Raspberry Pi OS in particular ships
# several possible header packages depending on kernel flavor).
#
# Milestone: /lib/modules/$(uname -r)/build exists afterwards. That symlink
# (or directory) is what DKMS needs in the next stage; if it's missing here,
# the driver build in 30-driver.sh will fail with a much less obvious error.

stage_headers() {
    local build_dir="/lib/modules/${KVER}/build"

    if [ -e "$build_dir" ]; then
        log "Kernel headers already present: $build_dir"
        return 0
    fi

    local candidates=()
    case "$PLATFORM" in
        rpi-arm64)
            candidates=(
                "linux-headers-${KVER}"
                "linux-headers-rpi-v8"
                "linux-headers-rpi-2712"
                "raspberrypi-kernel-headers"
            )
            ;;
        debian-amd64)
            candidates=(
                "linux-headers-${KVER}"
                "linux-headers-amd64"
            )
            ;;
        *)
            die "No header package list for platform '$PLATFORM'"
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        log "Trying kernel header package: $pkg"
        if run apt-get install -y "$pkg"; then
            if [ "${DRY_RUN:-0}" = "1" ] || [ -e "$build_dir" ]; then
                log "Headers installed via $pkg"
                return 0
            fi
            warn "$pkg installed but $build_dir still missing -- trying next candidate"
        else
            warn "$pkg not available or failed to install -- trying next candidate"
        fi
    done

    die "Could not obtain kernel headers for $KVER on $PLATFORM. Tried: ${candidates[*]}. See docs/troubleshooting.md."
}
