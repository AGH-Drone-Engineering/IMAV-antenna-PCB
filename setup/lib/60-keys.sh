#!/usr/bin/env bash
# setup/lib/60-keys.sh — install or generate the wfb-ng keypair.
#
# wfb_keygen writes drone.key and gs.key together, as a MATCHED PAIR, into
# whatever directory you run it from (verified in the driver's own
# keygen.c). Running it again on EITHER end silently invalidates the other
# -- you'll see `sess` counters climbing in wfb-cli but `udp` staying at
# zero, with no error telling you why. So: generate once, distribute the
# counterpart out-of-band (scripts/wfb-keys-provision does this over the
# network that exists before the wfb-ng link does), and never re-run
# wfb_keygen on a host that already has its half of a working pair.

stage_keys() {
    local want other
    if [ "$ROLE" = "air" ]; then want=drone.key; other=gs.key; else want=gs.key; other=drone.key; fi

    if [ -n "$IMPORT_KEY" ]; then
        [ -f "$IMPORT_KEY" ] || die "--import-key file not found: $IMPORT_KEY"
        install -D -m 0600 "$IMPORT_KEY" "/etc/$want"
        log "Imported /etc/$want from $IMPORT_KEY"
        return 0
    fi

    if [ -f "/etc/$want" ]; then
        log "/etc/$want already exists -- keeping it. Pass --import-key to replace."
        return 0
    fi

    warn "No /etc/$want found. This host needs a keypair before the link can work."
    warn "Generating a NEW keypair here invalidates whatever /etc/$other the peer"
    warn "already has (if any) -- you'll need to re-distribute the counterpart."
    confirm_or_die "Generate a new wfb-ng keypair now?"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[dry-run] would run wfb_keygen in /etc and chmod 600 both halves"
        return 0
    fi

    ( cd /etc && wfb_keygen )
    chmod 0600 /etc/drone.key /etc/gs.key
    log "Generated /etc/drone.key and /etc/gs.key"
    log ""
    log "Next: copy the peer's half over and remove it from here. From this host:"
    log "    scp /etc/$other <peer-host>:/etc/$other"
    log "    ssh <peer-host> chmod 600 /etc/$other"
    log "    shred -u /etc/$other      # don't leave the peer's key lying around here"
    log ""
    log "Or just run: sudo ./scripts/wfb-keys-provision --role $ROLE <peer-host>   (does all of the above)"
}
