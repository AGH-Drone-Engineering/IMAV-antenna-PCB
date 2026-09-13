#!/usr/bin/env bash
# setup/lib/30-driver.sh — build and install the RTL8812EU/RTL8822EU driver
# via DKMS. THIS IS THE HIGHEST-RISK STAGE IN THE WHOLE INSTALLER: it's an
# out-of-tree vendor driver being built against whatever kernel happens to be
# running. Do this stage on both Pis before writing/trusting anything later
# in the pipeline.
#
# Deliberately does NOT run the driver's own dkms-install.sh, which appends
# IPv6-disabling lines to /etc/sysctl.conf on every invocation (verified in
# the driver's own source) -- a global side effect nobody asked for. We call
# `dkms add/build/install` ourselves instead.
#
# PACKAGE_NAME/PACKAGE_VERSION are read out of the driver's own dkms.conf
# after cloning, not hardcoded here -- see VERSIONS for why.

DRIVER_SRC_DIR="/usr/src/wfb-driver-src"   # scratch clone, not the DKMS tree itself
MODPROBE_CONF_SRC="$HERE/config/modprobe.d/10-wfb-rtl88x2eu.conf"
NM_CONF_SRC="$HERE/config/networkmanager/99-wfb-unmanaged.conf"

stage_driver() {
    local pkg_name pkg_ver dkms_id

    _driver_clone

    if [ "${DRY_RUN:-0}" = "1" ] && [ ! -f "$DRIVER_SRC_DIR/dkms.conf" ]; then
        # Dry-run correctly skipped the actual clone, so there's no real
        # dkms.conf to read PACKAGE_NAME/PACKAGE_VERSION from yet -- that's
        # expected, not an error. Nothing past this point can be meaningfully
        # simulated without the real source tree, so stop here for THIS
        # stage rather than reporting a false failure.
        log "[dry-run] would read PACKAGE_NAME/PACKAGE_VERSION from a real clone's dkms.conf, then dkms add/build/install against kernel $KVER"
        return 0
    fi

    pkg_name="$(_driver_dkms_field PACKAGE_NAME)"
    pkg_ver="$(_driver_dkms_field PACKAGE_VERSION)"
    [ -n "$pkg_name" ] && [ -n "$pkg_ver" ] || die "Could not read PACKAGE_NAME/PACKAGE_VERSION from $DRIVER_SRC_DIR/dkms.conf"
    dkms_id="${pkg_name}/${pkg_ver}"
    log "Driver identifies itself to DKMS as: $dkms_id"

    if dkms status "$dkms_id" 2>/dev/null | grep -q installed; then
        if [ "$FORCE_DRIVER" = "1" ]; then
            log "Already installed, but --force-driver given -- removing first"
            run dkms remove "$dkms_id" --all || true
        else
            log "$dkms_id already installed for this kernel -- skipping build. Use --force-driver to rebuild."
            _driver_install_support_files
            return 0
        fi
    fi

    _driver_patch_makefile_platform
    _driver_dkms_tree_setup "$pkg_name" "$pkg_ver"

    log "dkms add"
    run dkms add -m "$pkg_name" -v "$pkg_ver"

    log "dkms build (this compiles against KVER=$KVER -- if this fails, see docs/troubleshooting.md before assuming the pin is wrong)"
    if ! run dkms build -m "$pkg_name" -v "$pkg_ver"; then
        warn "Build failed. Check: /var/lib/dkms/${pkg_name}/${pkg_ver}/build/make.log"
        die "Driver build failed for $dkms_id against kernel $KVER. See docs/troubleshooting.md (fallback: VERSIONS documents an older pinned commit, and Bookworm as a fallback OS)."
    fi

    log "dkms install"
    run dkms install -m "$pkg_name" -v "$pkg_ver"

    _driver_install_support_files

    log "Reloading the module so this run takes effect without a reboot"
    run modprobe -r 8812eu 2>/dev/null || true
    run modprobe 8812eu || warn "modprobe 8812eu failed -- plug/replug the USB module or reboot, then check: dmesg | grep -i 8812eu"
}

_driver_clone() {
    if [ -d "$DRIVER_SRC_DIR/.git" ]; then
        log "Driver source already cloned at $DRIVER_SRC_DIR -- fetching pinned commit"
        run git -C "$DRIVER_SRC_DIR" fetch --depth 1 origin "$DRIVER_COMMIT"
        run git -C "$DRIVER_SRC_DIR" checkout --detach FETCH_HEAD
    else
        log "Cloning $DRIVER_REPO"
        run git clone --branch "$DRIVER_BRANCH" "$DRIVER_REPO" "$DRIVER_SRC_DIR"
        log "Checking out pinned commit $DRIVER_COMMIT"
        run git -C "$DRIVER_SRC_DIR" checkout --detach "$DRIVER_COMMIT"
    fi
}

# _driver_dkms_field NAME — pull a NAME="value" assignment out of dkms.conf.
# Under `set -e -o pipefail`, a `grep` that matches nothing would otherwise
# abort the whole script right here (pipefail propagates grep's exit 1 even
# though head/sed after it succeed) -- before stage_driver's own `die` with
# a clear explanation ever gets a chance to run. `|| true` keeps this
# function's own exit status 0 no matter what, so a missing field comes back
# as an empty string and stage_driver's explicit check produces the readable
# error instead of a bare, unexplained abort.
_driver_dkms_field() {
    local name="$1"
    grep -E "^${name}=" "$DRIVER_SRC_DIR/dkms.conf" | head -1 | sed -E "s/^${name}=\"?([^\"]*)\"?/\1/" || true
}

# Flip the Makefile's platform switches. Verified against the driver's own
# Makefile: CONFIG_PLATFORM_I386_PC defaults to 'y' (works unmodified for
# debian-amd64), CONFIG_PLATFORM_ARM64_RPI defaults to 'n' and must be
# flipped to 'y' for any arm64 Raspberry Pi / generic arm64 board -- its
# ifeq block sets ARCH=arm64 and the correct KSRC/MODDESTDIR for that case.
_driver_patch_makefile_platform() {
    local mk="$DRIVER_SRC_DIR/Makefile"
    [ -f "$mk" ] || die "$mk not found -- driver repo layout changed?"

    case "$PLATFORM" in
        rpi-arm64)
            log "Patching Makefile for arm64 (CONFIG_PLATFORM_ARM64_RPI=y, CONFIG_PLATFORM_I386_PC=n)"
            if [ "${DRY_RUN:-0}" != "1" ]; then
                sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$mk"
                sed -i 's/^CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' "$mk"
                grep -q '^CONFIG_PLATFORM_ARM64_RPI = y' "$mk" || die "Makefile patch didn't take -- CONFIG_PLATFORM_ARM64_RPI line not found/matched as expected. Driver Makefile may have changed; check manually."
            fi
            ;;
        debian-amd64)
            log "x86_64: Makefile default (CONFIG_PLATFORM_I386_PC=y) is already correct, no patch needed"
            ;;
        *)
            die "No Makefile platform patch defined for '$PLATFORM'"
            ;;
    esac
}

# Copy the (now-patched) source tree into DKMS's expected /usr/src/<name>-<ver>
# location. `dkms add -m/-v` (without -k/--source-tree) expects the source
# there; copying rather than symlinking keeps our scratch clone reusable.
_driver_dkms_tree_setup() {
    local pkg_name="$1" pkg_ver="$2"
    local dest="/usr/src/${pkg_name}-${pkg_ver}"

    if [ -d "$dest" ]; then
        log "Removing stale DKMS source tree at $dest"
        run rm -rf "$dest"
    fi
    log "Copying patched driver source to $dest"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        mkdir -p "$dest"
        cp -a "$DRIVER_SRC_DIR"/. "$dest"/
    fi
}

_driver_install_support_files() {
    install_file "$MODPROBE_CONF_SRC" /etc/modprobe.d/10-wfb-rtl88x2eu.conf
    if [ -f "$NM_CONF_SRC" ] && command -v nmcli >/dev/null 2>&1; then
        install_file "$NM_CONF_SRC" /etc/NetworkManager/conf.d/99-wfb-unmanaged.conf
        run systemctl reload NetworkManager 2>/dev/null || true
    fi
}
