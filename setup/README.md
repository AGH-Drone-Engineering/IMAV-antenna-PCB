# IMAV antenna link — setup

A long-range digital radio link between a drone and a ground station, built on
two [BL-M8812EU2](https://openfpv.com.ua/en/hardware/net-cards/rtl8812eu)
(RTL8812EU chipset) modules mounted on this repo's carrier board, running
[wfb-ng](https://github.com/svpcom/wfb-ng). Carries SSH and MAVLink, plus an
optional video stage — an IP camera over RTSP ships today, pluggable for
USB/HDMI or a Pi camera later (`docs/integration.md`).

This is not a WiFi network. The cards run in monitor mode and inject raw
802.11 frames — no AP, no association, no DHCP. wfb-ng multiplexes
everything into a few fixed streams that show up on both ends as plain UDP
sockets on localhost, plus an IP tunnel for anything else.

```
   drone (air)                                    ground station (gs)
 ┌───────────────┐        5 GHz, monitor mode      ┌───────────────┐
 │ Raspberry Pi   │◄══════════════════════════════►│ Raspberry Pi   │
 │ + BL-M8812EU2  │        wfb-ng, ch 165           │ + BL-M8812EU2  │
 │                │                                 │                │
 │ FC ─UART─ Pi   │── MAVLink stream ──────────────►│ Pi ─UDP:14550─ QGC
 │ sshd           │◄── IP tunnel (drone-wfb) ──────►│ gs-wfb tunnel ─ ssh
 └───────────────┘                                 └───────────────┘
   10.5.0.2/24                                        10.5.0.1/24
```

## Before you power anything on

- Both antennas must be fitted before transmitting, always. This module
  has no antenna-lost protection — transmitting without one destroys the
  power amplifier, with no warning from the hardware.
- Don't power the module from a Raspberry Pi USB port for real use — a
  Pi's USB budget is well under what this module draws at useful power.
  `POWER_SOURCE=usb-pi` (the default) caps TX power for bench bring-up
  only. See `docs/tuning.md` for the numbers and the other
  `POWER_SOURCE` options.
- Channel 165 (5825 MHz) is not EU-harmonised for general RLAN use.
  `WIFI_REGION` only lifts the driver's own restrictions — it does not
  make the transmission legal. See `docs/tuning.md` before transmitting
  at real power.

## Quickstart

```sh
# on the drone's Pi:
git clone <this-repo-url> && cd IMAV-antenna-PCB/setup
sudo ./install.sh --role air

# on the ground station's Pi:
git clone <this-repo-url> && cd IMAV-antenna-PCB/setup
sudo ./install.sh --role gs

# distribute keys (once per pair, on whichever host generated them):
sudo ./scripts/wfb-keys-provision --role air <ground-station-host>   # or --role gs <drone-host>

# verify:
sudo ./scripts/wfb-doctor
```

Full walkthrough: **[docs/install.md](docs/install.md)**.

## What to read next

| Need to... | Read |
|---|---|
| Install from a clean image, step by step | [docs/install.md](docs/install.md) |
| Run day-to-day: pre-flight check, `wfb-cli`, changing a setting, upgrades, uninstalling | [docs/operations.md](docs/operations.md) |
| Wire up SSH, MAVLink, or a camera | [docs/integration.md](docs/integration.md) |
| Diagnose a symptom | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Choose channel/bandwidth/power/antennas, or check the legal picture | [docs/tuning.md](docs/tuning.md) |

## Repo layout

| Path | What |
|---|---|
| `link.conf` | The one file you edit — channel, power, MAVLink, FEC, tunnel, video |
| `link.conf.local.example` | Copy to `link.conf.local` for host-specific overrides (gitignored) |
| `VERSIONS` | Pinned driver/wfb-ng versions |
| `install.sh` | Entrypoint — `sudo ./install.sh --role air\|gs [flags]`, see `--help` |
| `uninstall.sh` | Reverses `install.sh` — see `docs/operations.md` |
| `lib/` | Installer stages, run in order, each independently re-runnable (`--only`) |
| `config/` | Templates and system files the installer places, including `video-sources/` (pluggable camera modules) |
| `scripts/` | `wfb-doctor` (diagnostics) and `wfb-keys-provision` (key distribution), both usable standalone |
| `keys/` | Empty, gitignored placeholder — nothing writes here automatically; the installer places keys at `/etc/drone.key`/`/etc/gs.key` |
| `docs/` | Install walkthrough, operations, integration guide, troubleshooting, RF tuning |
