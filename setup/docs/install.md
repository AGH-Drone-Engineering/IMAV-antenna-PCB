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

1. Mount the BL-M8812EU2 module on the carrier board.
2. Fit both antennas now, before any power is applied, and leave them on
   for the rest of this guide. This chipset has no antenna-lost
   protection: transmitting without one destroys the amplifier.
3. Connect the module's USB-C to the Pi. `POWER_SOURCE=usb-pi` (the
   default in `link.conf`) is correct for this step — see
   `docs/tuning.md` before changing it.

## 2. Clone the repo

On both Pis:

```sh
git clone <this-repo-url>
cd IMAV-antenna-PCB/setup
```

## 3. Review `link.conf`

Defaults (channel 165, 20 MHz, MCS1, `POWER_SOURCE=usb-pi`) install as-is.
Change channel/power/etc. later with `--only 50-config` plus a service
restart, no reinstall needed. Nothing needs editing for a first install
unless MAVLink isn't coming from the Pi's own UART (`/dev/serial0`) — see
`docs/integration.md`.

## 4. Run the installer

Drone's Pi:

```sh
sudo ./install.sh --role air
```

Ground station's Pi:

```sh
sudo ./install.sh --role gs
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
  region, MCS, STBC, LDPC, short GI, link domain). Compare it between the
  two hosts once both have run this stage; a mismatch means one host's
  `link.conf` or `link.conf.local` differs from the other's in one of
  those fields.
- **`60-keys` prompts** to generate a new keypair if `/etc/drone.key` or
  `/etc/gs.key` is missing — expected on a first install, on exactly one
  of the two hosts (see step 5).
- **`80-payload` only acts on the air role**, and only when MAVLink comes
  over a UART (skipped if `MAVLINK_UDP_PORT` is set).
- With `VIDEO_ENABLE=0` (the default), `90-video` does nothing: no video
  packages installed, no units touched.

At the end the installer prints the next steps shown below (steps 5-7 of
this guide).

Every `link.conf` setting has a corresponding CLI flag for one-off
overrides — run `./install.sh --help` for the full list, including
`--dry-run` to preview what a run would do without writing anything.

## 5. Provision keys

Needs doing once per pair, on whichever host generated a new keypair (the
installer's prompt told you if it did — see `wfb_keygen`'s effect in
`lib/60-keys.sh` if you want the detail). From that host:

```sh
sudo ./scripts/wfb-keys-provision --role air <ground-station-host>
# or: sudo ./scripts/wfb-keys-provision --role gs <drone-host>
# (role = the ROLE of the host you're running this ON, not the peer)
```

This copies the peer's half of the keypair over SSH, verifies the hash of
the file at its final path on the peer, installs it with the right
permissions, and removes the local copy of the peer's half.

Requires root on this host (`sudo`) because it writes into `/etc`, and
reaches the peer using the SSH keys of the account you ran `sudo` from —
not root, since stock Raspberry Pi OS has no root SSH login. That same
account needs `sudo` rights on the peer. Both the SSH login and the peer's
`sudo` can prompt for a password; key-based SSH auth and `NOPASSWD` sudo
on the peer just mean no prompts. Pass a different peer-side account name
as the argument after the host if it differs from yours. See
`scripts/wfb-keys-provision --help`.

## 6. Reboot

The air unit's UART/console changes need a reboot to take effect:

```sh
sudo reboot
```

## 7. Verify

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
  either side means the two ends have mismatched keys (redo step 5).

If anything above doesn't match, `docs/troubleshooting.md` is organized
by which of these checks failed.

For interactive monitoring instead of a one-shot check: `wfb-cli drone`
(or `wfb-cli gs`) — a TUI, only useful over a real terminal (SSH with a
pty), not piped or scripted. See `docs/operations.md` for what its
columns mean.

Then: `docs/integration.md` to connect SSH, MAVLink, and (once a camera
is available) video.
