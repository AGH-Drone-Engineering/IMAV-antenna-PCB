#!/usr/bin/env bash
# setup/install.sh — entrypoint. See --help, or docs/install.md for the full
# walkthrough with expected output at each stage.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$HERE/lib/detect.sh"

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh --role air|gs [options]

Sets up a wfb-ng link on a BL-M8812EU2 module (RTL8812EU, 5 GHz).
Settings are read from ./link.conf, then ./link.conf.local; the flags
below take precedence over both.

REQUIRED
  --role air|gs            air = Raspberry Pi on the drone (wifibroadcast@drone,
                            /etc/drone.key, tunnel 10.5.0.2), gs = ground station
                            (wifibroadcast@gs, /etc/gs.key, tunnel 10.5.0.1).

RADIO  (must be identical on both ends)
  --channel N               5 GHz channel or a frequency in MHz  [WIFI_CHANNEL]
  --bandwidth 10|20          Channel width. 5 and 40 are rejected: 5 crashes
                             wfb_tx, 40 has a firmware injection bug.  [BANDWIDTH]
  --mcs N                    MCS index 0-7                          [MCS_INDEX]
  --region CODE              Driver regulatory domain               [WIFI_REGION]

POWER
  --power-source usb-pi|hub|external
                             Where the module gets power from. usb-pi caps
                             power for bench use; external/hub unlock the
                             full range.                          [POWER_SOURCE]
  --txpower N                dBm*100, 0-3150. Ceiling depends on --power-source;
                             above the PA saturation threshold requires
                             --i-know-what-im-doing.              [WIFI_TXPOWER]
  --i-know-what-im-doing     Allow WIFI_TXPOWER above the safety ceiling.

PAYLOAD
  --mavlink-serial DEV:BAUD  MAVLink source, e.g. /dev/serial0:115200.
                             /dev/ttyUSB0 works too. Paths containing '.' or
                             ':' (e.g. /dev/serial/by-id/...) are rejected by
                             wfb-ng's own parser -- use a short udev symlink
                             instead if you need one.        [MAVLINK_SERIAL]
  --mavlink-udp PORT         Air unit listens on this UDP port for MAVLink
                             instead of opening a serial device (companion
                             computer / SITL).           [MAVLINK_UDP_PORT]
  --qgc-host ADDR            Where to send MAVLink on the gs side   [QGC_HOST]
  --qgc-port N                UDP port for QGC                      [QGC_PORT]
  --enable-video              Turn on the video stage (90-video): on the air
                             role, installs and starts a pipeline for
                             VIDEO_SOURCE; on gs, enables rtsp@<codec> if
                             VIDEO_RTSP_SERVER=1. Configure VIDEO_* in
                             link.conf first -- see docs/integration.md.
                                                                [VIDEO_ENABLE]

KEYS
  --import-key FILE          Install an existing key instead of generating one.
                              Regenerating a keypair on one end silently
                              invalidates the other -- see scripts/wfb-keys-provision.

FLOW CONTROL
  --only STAGE                Run a single stage, e.g. --only 50-config.
                               Stages: 10-packages 20-headers 30-driver
                               40-wfb-ng 50-config 60-keys 70-services
                               80-payload 90-video
  --force-driver               Rebuild the DKMS driver even if already installed.
  --dry-run                    Print what would happen; change nothing.
  --yes                        Don't prompt for confirmation.
  -h, --help                   This screen.

EXAMPLES
  sudo ./install.sh --role air                     # drone's Pi
  sudo ./install.sh --role gs                      # ground station
  sudo ./install.sh --role air --only 50-config    # after editing link.conf
  sudo ./install.sh --role gs --qgc-host 192.168.1.50   # QGC on a laptop

  # moving from bench to field -- one flag, or one line in link.conf:
  sudo ./install.sh --role air --power-source external --txpower 1500 --only 50-config

  # camera arrived -- set VIDEO_* in link.conf, then on both ends:
  sudo ./install.sh --role air --enable-video --only 90-video
  sudo ./install.sh --role gs  --enable-video --only 90-video

WARNING: never transmit without both antennas fitted -- this module has no
antenna-lost protection and you will destroy the power amplifier.
EOF
}

ROLE=""
ONLY=""
DRY_RUN=0
ASSUME_YES=0
FORCE_DRIVER=0
IWKWID=0
OVERRIDE_CHANNEL=""
OVERRIDE_BANDWIDTH=""
OVERRIDE_MCS=""
OVERRIDE_REGION=""
OVERRIDE_POWER_SOURCE=""
OVERRIDE_TXPOWER=""
OVERRIDE_MAVLINK_SERIAL=""
OVERRIDE_MAVLINK_UDP_PORT=""
OVERRIDE_QGC_HOST=""
OVERRIDE_QGC_PORT=""
OVERRIDE_ENABLE_VIDEO=""
IMPORT_KEY=""

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --channel) OVERRIDE_CHANNEL="$2"; shift 2 ;;
        --bandwidth) OVERRIDE_BANDWIDTH="$2"; shift 2 ;;
        --mcs) OVERRIDE_MCS="$2"; shift 2 ;;
        --region) OVERRIDE_REGION="$2"; shift 2 ;;
        --power-source) OVERRIDE_POWER_SOURCE="$2"; shift 2 ;;
        --txpower) OVERRIDE_TXPOWER="$2"; shift 2 ;;
        --i-know-what-im-doing) IWKWID=1; shift ;;
        --mavlink-serial) OVERRIDE_MAVLINK_SERIAL="$2"; shift 2 ;;
        --mavlink-udp) OVERRIDE_MAVLINK_UDP_PORT="$2"; shift 2 ;;
        --qgc-host) OVERRIDE_QGC_HOST="$2"; shift 2 ;;
        --qgc-port) OVERRIDE_QGC_PORT="$2"; shift 2 ;;
        --enable-video) OVERRIDE_ENABLE_VIDEO=1; shift ;;
        --import-key) IMPORT_KEY="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --force-driver) FORCE_DRIVER=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ "$ROLE" =~ ^(air|gs)$ ]] || die "--role air|gs is required (see --help)"

need_root
detect_platform

# --- load config layers: link.conf -> link.conf.local -> CLI overrides -----
[ -f "$HERE/link.conf" ] || die "Missing $HERE/link.conf -- this shouldn't happen in a checked-out repo."
# shellcheck source=link.conf
source "$HERE/link.conf"

# Radio-section values must match on both ends of the link. Snapshot them
# before link.conf.local can touch anything, so we can warn if a host-local
# override quietly breaks that parity.
RADIO_VARS=(WIFI_CHANNEL BANDWIDTH WIFI_REGION MCS_INDEX STBC LDPC SHORT_GI LINK_DOMAIN)
for v in "${RADIO_VARS[@]}"; do declare "_before_$v=${!v}"; done

if [ -f "$HERE/link.conf.local" ]; then
    log "Loading link.conf.local (host-specific overrides)"
    # shellcheck source=/dev/null
    source "$HERE/link.conf.local"
fi

for v in "${RADIO_VARS[@]}"; do
    before_var="_before_$v"
    if [ "${!before_var}" != "${!v}" ]; then
        warn "link.conf.local overrides RADIO setting $v (${!before_var} -> ${!v})."
        warn "This value must be IDENTICAL on both ends of the link -- make sure"
        warn "the peer's effective value matches, or the link will be dead or"
        warn "one-way with no readable error. Consider putting this in link.conf"
        warn "instead if it's meant to apply to the whole flight, not just this host."
    fi
done

[ -n "$OVERRIDE_CHANNEL" ] && WIFI_CHANNEL="$OVERRIDE_CHANNEL"
[ -n "$OVERRIDE_BANDWIDTH" ] && BANDWIDTH="$OVERRIDE_BANDWIDTH"
[ -n "$OVERRIDE_MCS" ] && MCS_INDEX="$OVERRIDE_MCS"
[ -n "$OVERRIDE_REGION" ] && WIFI_REGION="$OVERRIDE_REGION"
[ -n "$OVERRIDE_POWER_SOURCE" ] && POWER_SOURCE="$OVERRIDE_POWER_SOURCE"
[ -n "$OVERRIDE_TXPOWER" ] && WIFI_TXPOWER="$OVERRIDE_TXPOWER"
[ -n "$OVERRIDE_MAVLINK_SERIAL" ] && MAVLINK_SERIAL="${OVERRIDE_MAVLINK_SERIAL%%:*}" && MAVLINK_BAUD="${OVERRIDE_MAVLINK_SERIAL##*:}"
[ -n "$OVERRIDE_MAVLINK_UDP_PORT" ] && MAVLINK_UDP_PORT="$OVERRIDE_MAVLINK_UDP_PORT"
[ -n "$OVERRIDE_QGC_HOST" ] && QGC_HOST="$OVERRIDE_QGC_HOST"
[ -n "$OVERRIDE_QGC_PORT" ] && QGC_PORT="$OVERRIDE_QGC_PORT"
[ -n "$OVERRIDE_ENABLE_VIDEO" ] && VIDEO_ENABLE=1

export ROLE DRY_RUN ASSUME_YES FORCE_DRIVER IWKWID IMPORT_KEY HERE ORIG_ARGS
export PLATFORM CODENAME ARCH KVER PI_MODEL
export WIFI_CHANNEL BANDWIDTH WIFI_REGION MCS_INDEX STBC LDPC SHORT_GI LINK_DOMAIN
export POWER_SOURCE WIFI_TXPOWER TXPOWER_MAX_USB TXPOWER_MAX_EXTERNAL
export FEC_MAVLINK_K FEC_MAVLINK_N FEC_MAVLINK_TIMEOUT
export FEC_TUNNEL_K FEC_TUNNEL_N FEC_TUNNEL_TIMEOUT
export FEC_VIDEO_K FEC_VIDEO_N
export MAVLINK_SERIAL MAVLINK_BAUD MAVLINK_UDP_PORT QGC_HOST QGC_PORT MAVLINK_SYS_ID
export TUNNEL_IP_AIR TUNNEL_IP_GS TUNNEL_PREFIX
export VIDEO_ENABLE VIDEO_SOURCE VIDEO_CAM_URL VIDEO_DEV
export VIDEO_WIDTH VIDEO_HEIGHT VIDEO_FPS VIDEO_BITRATE_KBPS
export VIDEO_CODEC VIDEO_RTSP_LATENCY VIDEO_RTSP_PROTOCOLS VIDEO_RTSP_SERVER
# shellcheck source=VERSIONS
source "$HERE/VERSIONS"
export DRIVER_REPO DRIVER_BRANCH DRIVER_COMMIT
export WFB_APT_COMPONENT WFB_VERSION

banner_safety_warning() {
    warn "=================================================================="
    warn " BOTH ANTENNAS MUST BE FITTED BEFORE THIS MODULE TRANSMITS."
    warn " This chipset has no antenna-lost protection -- transmitting"
    warn " without one destroys the power amplifier, silently."
    warn ""
    warn " POWER_SOURCE=$POWER_SOURCE, WIFI_TXPOWER=$WIFI_TXPOWER"
    if [ "$POWER_SOURCE" = "usb-pi" ]; then
        warn " Bus-powered from a Pi USB port -- bench use only. See link.conf."
    fi
    warn "=================================================================="
}
banner_safety_warning

STAGES=(10-packages 20-headers 30-driver 40-wfb-ng 50-config 60-keys 70-services 80-payload 90-video)

for s in "${STAGES[@]}"; do
    if [ -n "$ONLY" ] && [ "$ONLY" != "$s" ]; then
        continue
    fi
    log "==> stage $s"
    # shellcheck source=/dev/null
    source "$HERE/lib/$s.sh"
    # Stage file "40-wfb-ng.sh" -> function "stage_wfb_ng": strip the leading
    # "NN-", then normalize every remaining hyphen to an underscore (bash
    # function names CAN contain hyphens, but the .sh files use underscores
    # for readability, so both sides need to agree on that normalization).
    fn="stage_${s#*-}"
    fn="${fn//-/_}"
    "$fn"
done

print_next_steps() {
    local profile="gs"
    [ "$ROLE" = "air" ] && profile="drone"
    log ""
    if [ -n "$ONLY" ]; then
        log "Done with stage $ONLY."
        return 0
    fi
    log "Done. Next steps:"
    log "  1. If this is the first install on this pair, provision keys:"
    log "       sudo ./scripts/wfb-keys-provision --role $ROLE <peer-host>"
    log "  2. Reboot to pick up UART/console changes (air role) and confirm"
    log "     the driver survives a reboot: dkms status"
    log "  3. Verify: wfb-cli $profile   (see docs/install.md)"
}
print_next_steps
