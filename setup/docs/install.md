# Installing the link

Step by step from a clean Raspberry Pi OS Trixie (64-bit) image, on both the
drone's Pi and the ground station's Pi. Commands to copy, and what you should
see at each step.

## 0. Before you start

- **Flash Raspberry Pi OS Trixie, 64-bit**, to both SD cards. Use Raspberry
  Pi Imager's advanced options to set a hostname, enable SSH, and put the Pi
  on your normal WiFi (`wlan0`) — you need a way to reach it that doesn't
  depend on the radio link you're about to build, and you'll want it later
  too (`wlan0` stays under NetworkManager the whole time; only the
  BL-M8812EU2 goes into monitor mode).
- Confirm you can `ssh` into both Pis over that network before touching
  anything else.
- **Do not plug in the BL-M8812EU2 module or apply carrier-board power yet.**

## 1. Carrier board and module

1. Mount the BL-M8812EU2 module on the carrier board.
2. **Fit both antennas now, before any power is applied, and leave them on
   for the rest of this guide.** This chipset has no antenna-lost
   protection — transmitting without one destroys the amplifier, silently.
3. For this install process, `POWER_SOURCE=usb-pi` (the default in
   `link.conf`) is fine — you're just bringing the driver and config up,
   not testing range. Connect the module's USB-C to the Pi.
4. For anything beyond bench bring-up, power from the carrier board's
   battery/BEC leads (`J1`/`J3`) with switch `S1` in the `V_batt` position —
   see the `POWER_SOURCE` section of `link.conf` and `docs/tuning.md`.

## 2. Clone the repo

On **both** Pis:

```sh
git clone <this-repo-url>
cd IMAV-antenna-PCB/setup
```

## 3. Review `link.conf`

The defaults (channel 165, 20 MHz, MCS1, `POWER_SOURCE=usb-pi`) are fine to
install with as-is — you can change channel/power later with `--only
50-config` and a restart, no reinstall needed. Read through it once anyway;
every value has a comment explaining why it's set the way it is. Nothing
here needs editing for a first install unless your MAVLink source isn't the
Pi's own UART (`/dev/serial0`) — see `docs/integration.md`.

## 4. Run the installer

On the **drone's** Pi:

```sh
sudo ./install.sh --role air
```

On the **ground station's** Pi:

```sh
sudo ./install.sh --role gs
```

Expected output, stage by stage (both roles look the same up through the
driver build):

```
[!] ==================================================================
[!]  BOTH ANTENNAS MUST BE FITTED BEFORE THIS MODULE TRANSMITS.
[!]  ...
[!] ==================================================================
[+] platform=rpi-arm64 codename=trixie arch=arm64 kernel=6.12... model="Raspberry Pi ..."
[+] ==> stage 10-packages
...
[+] ==> stage 20-headers
[+] Kernel headers already present: /lib/modules/.../build
[+] ==> stage 30-driver
[+] Cloning https://github.com/libc0607/rtl88x2eu-20230815.git
[+] Checking out pinned commit 934f0dc0b842ec09886a1d50a71cb271d7561d23
[+] Driver identifies itself to DKMS as: realtek-rtl88x2eu/5.15.0.1~20230815
[+] Patching Makefile for arm64 (CONFIG_PLATFORM_ARM64_RPI=y, CONFIG_PLATFORM_I386_PC=n)
[+] dkms add
[+] dkms build (this compiles against KVER=... -- if this fails, see docs/troubleshooting.md ...)
[+] dkms install
...
[+] ==> stage 40-wfb-ng
[+] Adding apt.wfb-ng.org repository (component: master)
[+] Installing wfb-ng=26.8.27.51673-0~trixie (component: master)
[+] wfb_tun present (tunnel/SSH path is available)
[+] ==> stage 50-config
[+] MAVLink: air unit will open /dev/serial0 @ 115200 baud
[+] Wrote /etc/wifibroadcast.cfg
[+] Effective radio-section fingerprint (compare this to the peer -- must match): a1b2c3d4e5f6a7b8
[+] ==> stage 60-keys
[!] No /etc/drone.key found. This host needs a keypair before the link can work.
Generate a new wfb-ng keypair now? [y/N] y
[+] Generated /etc/drone.key and /etc/gs.key
...
[+] ==> stage 70-services
[+] wifibroadcast@drone is active.
[+] ==> stage 80-payload
[+] Adding enable_uart=1 to /boot/firmware/config.txt
[+] Removing serial console entry from /boot/firmware/cmdline.txt
[+] ==> stage 90-video
[+] VIDEO_ENABLE=0 -- skipping the video stage entirely (no packages installed, no units touched).
[+] Done. Next steps:
[+]   1. If this is the first install on this pair, provision keys:
[+]        ./scripts/wfb-keys-provision --role air <peer-host>
[+]   2. Reboot to pick up UART/console changes ...
[+]   3. Verify: wfb-cli drone
```

**Stop and look at the driver build's output.** This is the single riskiest
step in the whole installer — an out-of-tree kernel module being compiled
against whatever kernel your image ships. If it fails here, don't touch
anything else; go straight to `docs/troubleshooting.md`.

**Check the "effective radio-section fingerprint" line on both hosts.** If
they don't match, something in `link.conf` differs between the two ends
(different edits, or one host has a `link.conf.local` override touching a
radio-section value) — fix that before moving on.

## 5. Provision keys

Only needs doing once, on whichever host generated a new keypair (the
installer told you if it did). From that host:

```sh
./scripts/wfb-keys-provision --role air <ground-station-host>
# (or --role gs <drone-host>, matching whichever role THIS host is)
```

This copies the peer's half of the keypair over SSH, verifies it arrived
byte-for-byte intact, installs it with the right permissions on the peer,
and removes the local copy (you never want both halves sitting on one
host). See `scripts/wfb-keys-provision --help`.

## 6. Reboot

The air unit's UART/console changes need a reboot to take effect:

```sh
sudo reboot
```

## 7. Verify

See `docs/troubleshooting.md`'s checklist, or the short version:

```sh
wfb-cli drone      # on the drone; wfb-cli gs on the ground station
```

You should see non-zero `udp` counters and RSSI/SNR on both antenna columns
within a few seconds of both services being up. If not, `./scripts/wfb-doctor`
runs the standard set of checks in one shot.

Then: `docs/integration.md` for actually plugging in SSH, MAVLink, and (once
a camera is available) video — `VIDEO_ENABLE=0` by default, so this install
carried no video packages or services at all; turning it on later is a
`link.conf` edit plus `--only 90-video` on each end, not a reinstall.

## After a kernel update

The driver is an out-of-tree DKMS module — a kernel upgrade can silently
leave it unbuilt for the new kernel. **Before flying**, always check:

```sh
dkms status
```

If the currently running kernel isn't listed as `installed`, re-run:

```sh
sudo ./install.sh --role air --only 30-driver --force-driver
```

## Upgrading wfb-ng itself

`VERSIONS` pins an exact version on both ends and `apt-mark hold`s it —
deliberately, since Trixie only has the rolling `master` apt component (no
working stable channel there). To move to a newer version:

1. Pick a new version: `apt-cache madison wfb-ng`
2. Update `WFB_VERSION` in `setup/VERSIONS`, commit, and pull it to **both**
   hosts.
3. On each host: `sudo apt-mark unhold wfb-ng && sudo ./install.sh --role
   air|gs --only 40-wfb-ng`
4. Restart both services and re-verify with `wfb-cli`.

Do this on both ends together — a version mismatch between air and gs is a
real failure mode, not just a compatibility nicety.
