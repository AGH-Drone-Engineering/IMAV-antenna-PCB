# Operations: running an installed link

Everything you do after the first install, repeatedly.

## Autostart on boot

`wifibroadcast@drone`/`wifibroadcast@gs` is enabled to start at boot.
`wfb-video-air.service` and `rtsp@<codec>.service` (when video is on) are
independent units, enabled the same way.

`wifibroadcast@.service`'s own `[Install]` section is `WantedBy=` the
package's empty aggregate unit (`wifibroadcast.service`), not
`multi-user.target` — enabling only the instance leaves nothing to start
that aggregate unit at boot. `install.sh` enables both units for exactly
this reason (`lib/70-services.sh`). If a link that worked yesterday is
dead after a reboot with every stage otherwise fine, check:

```sh
systemctl is-enabled wifibroadcast.service
```

If it reports `disabled`, run `sudo systemctl enable wifibroadcast.service`
once, on that host.

## Pre-flight checklist

Before a flight, on both hosts:

```sh
sudo ./scripts/wfb-doctor
```

Confirm: USB device present, driver bound, `wifibroadcast@<profile>`
active, tunnel interface up, stream stats non-zero on both ends with
`d_err`/`dec_err` at zero. See `docs/install.md`'s verification section
for what each line means.

After a kernel update (`apt upgrade` that touched the kernel), before
anything else:

```sh
dkms status
```

The currently running kernel (`uname -r`) must be listed as `installed`.
An out-of-tree DKMS module does not automatically exist for a kernel it
hasn't been built against. If it's missing or shows `added` instead:

```sh
sudo ./install.sh --role air|gs --only 30-driver --force-driver
```

## Changing a setting

1. Edit `link.conf` (or `link.conf.local` for a host-specific override).
2. On each affected host:
   ```sh
   sudo ./install.sh --role air|gs --only 50-config
   sudo systemctl restart wifibroadcast@drone   # or @gs
   ```
3. For a change to `WIFI_CHANNEL`, `BANDWIDTH`, `MCS_INDEX`, `LINK_DOMAIN`
   (in SETTINGS), or `WIFI_REGION`, `STBC`, `LDPC`, `SHORT_GI` (in
   INTERNALS) — all eight must match on both ends — do this on **both**
   hosts and compare the fingerprint `--only 50-config` prints.
4. For a `VIDEO_*` change: `sudo ./install.sh --role air|gs --only
   90-video` instead of `50-config`, on both ends if `VIDEO_CODEC`
   changed.

## Reading `wfb-cli`

`wfb-cli drone` (or `wfb-cli gs`) is an interactive full-screen display —
needs a real terminal (SSH with a pty), refreshes once per second, exits
with `q` or Ctrl-C. One panel per configured stream (video, mavlink,
tunnel), split into an RX side and a TX side depending on which end of
that stream this host is.

RX panel, per-second rate (cumulative count in parens):

| Field | Meaning |
|---|---|
| `recv` | Packets received over the air, before dedup |
| `udp` | Packets delivered to the local consumer (decoded, deduped) |
| `sess` | Session/key-negotiation packets |
| `fec_r` | Packets recovered by FEC |
| `lost` | Packets lost outright (not recovered by FEC) |
| `d_err` | Decrypt errors — non-zero here means the two ends' keys don't match |
| `bad` | Malformed packets |

Also shown: `Flow` (bitrate in → out), `FEC` (configured k/n), `Diversity`
(ratio of packets counted per-antenna vs. unique packets after dedup —
above 1.0 means more than one antenna is hearing the same packet).

Per-antenna row: packets/s, `dloss` (that antenna's packets lost to
dedup against a better antenna), RSSI `min < avg < max` (dBm), SNR
`min < avg < max` (dB). No fixed good/bad threshold — track trend and
compare antennas relative to each other; a stable, high SNR beats a
noisy, higher-average one.

TX panel, per-second rate (cumulative count in parens):

| Field | Meaning |
|---|---|
| `sent` | Packets injected onto the air |
| `udp` | Packets received from the local producer, before FEC/injection |
| `fec_t` | FEC blocks force-closed by timeout (partial block, not full) |
| `drop` | Packets dropped before injection (queue full) |
| `trunc` | Packets truncated — payload exceeded `radio_mtu` (1445); the shipped `rtsp` pipeline's `mtu=1400` is sized to avoid this |

Also shown per antenna: injection rate, RF temperature, injection latency
`min < avg < max` (microseconds).

## Upgrading wfb-ng

`setup/VERSIONS` pins an exact `wfb-ng` version and `apt-mark hold`s it —
Trixie's only working apt component is the rolling `master` snapshot, so
both ends must move together deliberately rather than drift apart on
their own schedule.

1. `apt-cache madison wfb-ng` to see available versions.
2. Update `WFB_VERSION` in `setup/VERSIONS`, commit, pull to both hosts.
3. On each host:
   ```sh
   sudo apt-mark unhold wfb-ng
   sudo ./install.sh --role air|gs --only 40-wfb-ng
   ```
4. Restart both services and re-verify with `sudo ./scripts/wfb-doctor`.

Do this on both ends together — a version mismatch between air and gs is
a real failure mode, not a compatibility nicety.

## Uninstalling

```sh
sudo ./uninstall.sh
```

Stops and disables `wifibroadcast@drone`/`@gs`, the aggregate
`wifibroadcast.service`, and the video units; removes the DKMS driver;
purges the `wfb-ng` apt package; removes the modprobe/NetworkManager/video
files `install.sh` placed. Leaves `/etc/drone.key`/`/etc/gs.key` and boot
config changes (`config.txt`/`cmdline.txt`) alone — their `.bak.<timestamp>`
copies sit next to the originals if you want those back too.
