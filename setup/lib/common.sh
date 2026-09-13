#!/usr/bin/env bash
# setup/lib/common.sh — shared helpers, sourced by install.sh and every
# lib/NN-*.sh stage. Not meant to be run directly.

# Colors only when stdout is a real terminal, so piped/logged output stays clean.
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
fi

log()  { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# run CMD [ARGS...] — echo the command before executing it (unless DRY_RUN),
# so installer output doubles as a transcript of exactly what happened.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '    %s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"
        return 0
    fi
    printf '    %s\n' "$*"
    "$@"
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "This stage must run as root. Try: sudo $0 ${ORIG_ARGS[*]:-}"
}

# confirm_or_die PROMPT — skipped entirely when --yes was passed.
confirm_or_die() {
    local prompt="$1"
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    read -r -p "$prompt [y/N] " reply </dev/tty
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) die "Aborted by user." ;;
    esac
}

# backup_file PATH — copy PATH to PATH.bak.<timestamp> if it exists and isn't
# already one of ours. Never overwrites a previous backup.
backup_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    local ts; ts="$(date +%Y%m%d%H%M%S)"
    local bak="${f}.bak.${ts}"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would back up $f -> $bak"
        return 0
    fi
    cp -p "$f" "$bak"
    log "Backed up $f -> $bak"
}

# install_file SRC DST [MODE] — backs up DST if present, then copies SRC over
# it. MODE defaults to 0644.
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    backup_file "$dst"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would install $src -> $dst (mode $mode)"
        return 0
    fi
    install -D -m "$mode" "$src" "$dst"
    log "Installed $dst"
}

# render_template SRC DST VARS — substitute ${VAR}/$VAR placeholders in SRC
# using the current shell environment, write result to DST. VARS is a
# whitespace-separated list like '$WIFI_CHANNEL $BANDWIDTH' naming exactly
# which variables to substitute (envsubst with an explicit list), so nothing
# else in the file that happens to contain a literal '$' is touched. Used by
# lib/50-config.sh.
render_template() {
    local src="$1" dst="$2" vars="$3"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would render $src -> $dst"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    # shellcheck disable=SC2016
    envsubst "$vars" < "$src" > "$dst"
}

# sha256_short FILE — first 16 hex chars of a file's SHA-256, for
# human-comparable fingerprints (radio config parity, keys) without dumping
# full hashes.
sha256_short() {
    sha256sum "$1" 2>/dev/null | cut -c1-16
}
