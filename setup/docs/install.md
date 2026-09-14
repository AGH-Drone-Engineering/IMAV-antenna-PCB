# Installing the link

From a clean Raspberry Pi OS Trixie (64-bit) image to a working link, on
both the drone's Pi and the ground station's Pi.

## 0. Before you start

- Flash Raspberry Pi OS Trixie, 64-bit, to both SD cards. Use Raspberry Pi
  Imager's advanced options to set a hostname, enable SSH, and put the Pi
  on your normal WiFi (`wlan0`) — you need a way to reach it that doesn't
  depend on the radio link you're about to build. `wlan0` stays under
  NetworkManager the whole time; only the BL-M8812EU2 goes into monitor
  mode.
- Confirm `ssh` into both Pis works over that network before touching
  anything else.
- Do not plug in the BL-M8812EU2 module or apply carrier-board power yet.

## 1. Carrier board and module

On both Pis:

1. Mount the BL-M8812EU2 module on the carrier board.
2. Fit both antennas now, before any power is applied, and leave them on
   for the rest of this guide. This chipset has no antenna-lost
   protection: transmitting without one destroys the amplifier.
3. Connect the module's USB-C to the Pi. **`link.conf` ships set for field
   use (`POWER_SOURCE=external`, `WIFI_TXPOWER=1500`) — not for this bench
   step.** `install.sh` validates `WIFI_TXPOWER` against whatever
   `POWER_SOURCE` you declare, not against how the module is actually
   wired, so it will not catch this on its own. Before running the
   installer, create `link.conf.local` (copy
   `link.conf.local.example`) with:
   ```sh
   POWER_SOURCE=usb-pi
   WIFI_TXPOWER=500
   ```
   Delete that file once the module is genuinely powered from the carrier
   board's battery/BEC leads. See `docs/tuning.md` for why both lines are
   needed together.

## 2. Drone's Pi: clone and install

```sh
git clone <this-repo-url>
cd IMAV-antenna-PCB/setup
```

`link.conf`'s defaults (channel 165, 20 MHz, MCS1) install as-is. Change
channel/power/etc. later with `--only 50-config` plus a service restart,
no reinstall needed. Nothing needs editing for a first install unless
MAVLink isn't coming from the Pi's own UART (`/dev/serial0`) — see
`docs/integration.md`.

```sh
sudo ./install.sh --role air
```

What happens, in order: platform detection, then the antenna safety
warning, then each stage in `10-packages 20-headers 30-driver 40-wfb-ng
50-config 60-keys 70-services 80-payload 90-video`.

Points to watch for:

- **`30-driver` is the riskiest stage** — an out-of-tree kernel module
  compiled against whatever kernel your image ships. If it fails here,
  stop and go to `docs/troubleshooting.md` before touching anything else.
- **`40-wfb-ng` builds `wfb_tun` from source.** The `.deb` from
  `apt.wfb-ng.org` does not ship this binary; the installer detects that
  and builds it itself from the exact commit the installed package came
  from. Expect a `git clone`/`make` here, not just an `apt install`.
- **`50-config` prints a radio-section fingerprint** — a short hash of
  the settings that must be identical on both ends (channel, bandwidth,
  region, MCS, STBC, LDPC, short GI, link domain). Compare it against the
  ground station's once you've installed there too (step 4); a mismatch
  means one host's `link.conf` or `link.conf.local` differs from the
  other's in one of those fields.
- **`60-keys` finds no `/etc/drone.key` on this, the first host in the
  pair, and prompts to generate a new keypair.** Answer `y`. This creates
  both `/etc/drone.key` (this host's) and `/etc/gs.key` (the ground
  station's, temporarily, until step 3 ships it over).
- **`80-payload` only acts on the air role**, and only when MAVLink comes
  over a UART (skipped if `MAVLINK_UDP_PORT` is set).
- With `VIDEO_ENABLE=0` (the default), `90-video` does nothing: no video
  packages installed, no units touched.

Every `link.conf` setting has a corresponding CLI flag for one-off
overrides — run `./install.sh --help` for the full list, including
`--dry-run` to preview what a run would do without writing anything.

## 3. Provision keys

Do this now, from the drone's Pi, before installing the ground station —
its own install will find the key already in place and skip the
generate-a-keypair prompt entirely.

```sh
sudo ./scripts/wfb-keys-provision --role air <ground-station-host>
```

This copies `/etc/gs.key` to the ground station over SSH, verifies the
hash of the file at its final path there, installs it with the right
permissions, and removes the local copy — this host keeps only
`/etc/drone.key` afterward.

Requires root on this host (`sudo`) because it writes into `/etc`, and
reaches the peer using the SSH keys of the account you ran `sudo` from —
not root, since stock Raspberry Pi OS has no root SSH login. That same
account needs `sudo` rights on the peer. Both the SSH login and the peer's
`sudo` can prompt for a password; key-based SSH auth and `NOPASSWD` sudo
on the peer just mean no prompts. Pass a different peer-side account name
as the argument after the host if it differs from yours. See
`scripts/wfb-keys-provision --help`.

Setting the ground station up first instead? Swap `air`/`gs` and
`drone.key`/`gs.key` throughout steps 2-4 — whichever host you install
first is the one that generates the pair.

## 4. Ground station's Pi: clone and install

```sh
git clone <this-repo-url>
cd IMAV-antenna-PCB/setup
sudo ./install.sh --role gs
```

Same stages as step 2, with one difference: `60-keys` finds `/etc/gs.key`
already there (from step 3) and logs `already exists -- keeping it`
instead of prompting. If it prompts to generate a new keypair instead,
step 3 didn't reach this host — stop and re-check it before continuing;
answering `y` here would create a second, unrelated pair.

## 5. Reboot

The air unit's UART/console changes need a reboot to take effect:

```sh
sudo reboot
```

## 6. Verify

```sh
sudo ./scripts/wfb-doctor
```

Run as root — some of its checks (DKMS status, `ethtool`) live in
`/usr/sbin`, off the default non-root `PATH`, and are silently skipped
without it. Expect:

- USB enumeration: `0bda:a81a`.
- Kernel driver: an interface reported by `wfb-nics`, driver `rtl88x2eu`.
- `wifibroadcast@drone` (air) or `wifibroadcast@gs` (gs): `active`.
- Tunnel interface (`drone-wfb`/`gs-wfb`) present with an address.
- Stream stats: non-zero `incoming`/`injected` on the tx side that's
  actually sending, non-zero `all` with `dec_err=0` on the rx side. Needs
  both ends up and passing real traffic — `dec_err` staying nonzero on
  either side means the two ends have mismatched keys (redo step 3).

If anything above doesn't match, `docs/troubleshooting.md` is organized
by which of these checks failed.

For interactive monitoring instead of a one-shot check: `wfb-cli drone`
(or `wfb-cli gs`) — a TUI, only useful over a real terminal (SSH with a
pty), not piped or scripted. See `docs/operations.md` for what its
columns mean.

Then: `docs/integration.md` to connect SSH, MAVLink, and (once a camera
is available) video.
