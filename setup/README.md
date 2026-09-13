# IMAV antenna link — setup

A long-range digital radio link between a drone and a ground station, built on
two [BL-M8812EU2](https://openfpv.com.ua/en/hardware/net-cards/rtl8812eu)
(RTL8812EU chipset) modules mounted on this repo's carrier board, running
[wfb-ng](https://github.com/svpcom/wfb-ng). Carries **SSH and MAVLink**, plus
an optional **video** stage — an IP camera over RTSP ships today, and the
source is pluggable (USB/HDMI, Pi camera) for later — see `docs/integration.md`.

This is **not** a WiFi network. The cards run in monitor mode and inject raw
802.11 frames — there's no AP, no association, no DHCP. wfb-ng multiplexes
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

## Quickstart

```sh
# on the drone's Pi:
git clone <this-repo-url> && cd IMAV-antenna-PCB/setup
sudo ./install.sh --role air

# on the ground station's Pi:
git clone <this-repo-url> && cd IMAV-antenna-PCB/setup
sudo ./install.sh --role gs

# distribute keys (run on whichever host generated them, needs SSH to the peer):
./scripts/wfb-keys-provision --role air <ground-station-host>   # or --role gs <drone-host>

# verify:
wfb-cli drone   # or: wfb-cli gs
```

Full step-by-step with expected output: **[docs/install.md](docs/install.md)**.
How to actually plug in SSH/MAVLink (and later a camera):
**[docs/integration.md](docs/integration.md)**.

## Before you power anything on

- **Both antennas must be fitted before transmitting, always.** This module
  has no antenna-lost protection — transmitting without one destroys the
  power amplifier. There is no warning from the hardware; it just dies.
- **Don't power the module from a Raspberry Pi USB port for real use.**
  See the `POWER_SOURCE` section in [link.conf](link.conf) — a Pi's USB
  budget (1.2–1.6 A total, shared across all ports) is well under what this
  module draws at useful power. `POWER_SOURCE=usb-pi` (the default) caps TX
  power low enough for bench bring-up only. For anything else, power the
  module from the carrier board's battery/BEC leads and flip one line in
  `link.conf`.
- **Channel 165 (5825 MHz) is not EU-harmonised for RLAN use.** `wifi_region`
  only lifts the driver's own restrictions — it does not make the
  transmission legal. See [docs/tuning.md](docs/tuning.md) before
  transmitting at real power.

## Repo layout

| Path | What |
|---|---|
| `link.conf` | **The one file you edit** — channel, power, MAVLink, FEC, tunnel |
| `link.conf.local.example` | Copy to `link.conf.local` for host-specific overrides |
| `VERSIONS` | Pinned driver/wfb-ng versions (maintainer-level, not operator-level) |
| `install.sh` | Entrypoint — `sudo ./install.sh --role air\|gs [flags]`, see `--help` |
| `lib/` | Installer stages, run in order, each independently re-runnable (`--only`) |
| `config/` | Templates and system files the installer places (includes `video-sources/` — pluggable camera modules) |
| `scripts/` | Diagnostics and key provisioning, also usable standalone |
| `docs/` | Install walkthrough, integration guide, troubleshooting, RF tuning |

## Docs

- **[docs/install.md](docs/install.md)** — installing on both Pis from a clean OS image
- **[docs/integration.md](docs/integration.md)** — wiring up SSH, MAVLink, and a camera
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — symptom → cause → command
- **[docs/tuning.md](docs/tuning.md)** — MCS/bandwidth tradeoffs, antennas, power ladder, the legal picture
