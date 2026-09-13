#!/usr/bin/env bash
# setup/lib/10-packages.sh — base apt dependencies. Kernel headers are
# handled separately in 20-headers.sh because the package name varies by
# platform and needs its own fallback chain.

stage_packages() {
    log "Updating apt package index"
    run apt-get update -qq

    local pkgs=(
        build-essential dkms git
        gnupg ca-certificates
        iw usbutils ethtool
        envsubst
    )
    # envsubst ships in gettext-base on Debian/Ubuntu, not as its own package name.
    pkgs=("${pkgs[@]/envsubst/gettext-base}")

    log "Installing: ${pkgs[*]}"
    run apt-get install -y "${pkgs[@]}"
}
