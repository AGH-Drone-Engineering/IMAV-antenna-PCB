# Tuning: legal constraints, range, and bandwidth

Read this before transmitting at any power beyond a quiet desk test.

## Legal constraints

Channel 165 (5825 MHz) is not EU-harmonised for general RLAN use. EN 301 893
harmonises 5150-5250, 5250-5350, and 5470-5725 MHz (up to 1 W EIRP in the
last, with DFS/TPC requirements). 5725-5850 MHz — where channel 165 sits,
and where FPV convention calls "5.8 GHz" — falls under Annex B of the same
standard: "subject to national frequency conditions." In Poland this range
is not available for general-purpose use without separate authorization.

`WIFI_REGION=BO` in `link.conf` lifts the driver's own channel/power/DFS
restrictions. It does not create legal authorization. Routes to
authorization: a frequency assignment from UKE, an amateur radio license
(secondary allocation overlapping part of this range), or an event
organizer's frequency coordination.

## Antennas

This card is 2T2R with two IPEX ports. Antenna gain dominates every other
tuning knob: 2 dBi to 5 dBi dipoles on both ends is +6 dB of link budget,
roughly doubling range. A ground-side patch or panel antenna (8-14 dBi)
adds more, at the cost of needing to point it at the aircraft.

Mount the air unit's two antennas with angular separation, not parallel.
A greater than 10 dB gap between `wfb-cli`'s two per-antenna RSSI columns
on a card that should be seeing the same signal indicates a bad connector
or a damaged antenna.

## Bandwidth and MCS

Rates for HT (802.11n), 1 spatial stream, long guard interval — this
hardware's operating mode (2T2R with STBC, not multi-stream):

| MCS | 20 MHz | 10 MHz | Modulation |
|---|---|---|---|
| 0 | 6.5 Mbit/s | 3.25 Mbit/s | BPSK 1/2 |
| **1** | **13 Mbit/s** | **6.5 Mbit/s** | QPSK 1/2 — default |
| 2 | 19.5 Mbit/s | 9.75 Mbit/s | QPSK 3/4 |
| 3 | 26 Mbit/s | 13 Mbit/s | 16-QAM 1/2 |
| 4 | 39 Mbit/s | 19.5 Mbit/s | 16-QAM 3/4 |
| 5 | 52 Mbit/s | 26 Mbit/s | 64-QAM 2/3 |
| 6 | 58.5 Mbit/s | 29.25 Mbit/s | 64-QAM 3/4 |
| 7 | 65 Mbit/s | 32.5 Mbit/s | 64-QAM 5/6 |

Each MCS step costs roughly 3-5 dB of link budget. `SHORT_GI=False`
(800 ns guard interval) tolerates multipath from ground reflections, at
~11% less throughput than `True`.

Halving bandwidth from 20 to 10 MHz halves the receiver noise floor
(~3 dB less thermal noise), giving ~1.4x range at the same MCS and half
the PHY rate. `BANDWIDTH=5` crashes `wfb_tx` (`Unsupported HT bandwidth: 5`).
`BANDWIDTH=40` has a firmware injection bug on this chipset. Only 10 and 20
are valid.

Bring the link up at `BANDWIDTH=20`; move to `10` once the link is proven
working, and re-measure.

## Power

Constraint: both antennas must be fitted before transmitting. This module
has no antenna-lost protection; transmitting without one destroys the
amplifier.

### Powering the module

A Raspberry Pi's USB budget is below what this module draws at useful
power: Pi 4 supplies 1.2 A total across all USB ports combined; Pi 5
supplies 1.6 A only with a genuine 5 A power supply, otherwise 600 mA,
shared with the fan header. The module's datasheet specifies 5V/>3A;
measured draw reaches 5V/2.x A at useful power and requires a heatsink with
a fan. There is no published curve mapping `WIFI_TXPOWER` to current draw.

`POWER_SOURCE` in `link.conf`:

| Value | Source | Ceiling |
|---|---|---|
| `usb-pi` | Raspberry Pi USB port | `TXPOWER_MAX_USB` — bench use only |
| `hub` | Powered USB hub or separate 5V rail, data over USB | `TXPOWER_MAX_EXTERNAL` |
| `external` | Carrier board battery/BEC (J1/J3), S1 to V_batt, heatsink fitted | `TXPOWER_MAX_EXTERNAL` |

Symptoms of exceeding the power budget: Pi resets under load, the link
drops under load, USB errors in `dmesg`.

### TX power

`WIFI_TXPOWER` for this chipset is dBm x100, positive (8812au uses negative
values for the same field; unrelated to OpenIPC's separate 0-63
`driver_txpower_override` scale). Roughly +5 dB per +500. The amplifier
saturates around 2000 — values above that add heat and spectral splatter
without adding range, and can reduce range by degrading the signal
constellation. The value is uncalibrated; treat every figure below as
relative, not absolute.

| `WIFI_TXPOWER` | Use |
|---|---|
| 300 | Desk test, transmitters a meter apart |
| 500 | Default, `POWER_SOURCE=usb-pi` |
| 800 | `TXPOWER_MAX_USB` ceiling |
| 1000-1500 | Field use with external power and a heatsink |
| 2000 | `TXPOWER_MAX_EXTERNAL` ceiling; PA saturation threshold |
| 3150 | Driver's hard maximum |

## FEC

`fec_k`/`fec_n` are block erasure coding: a block of `fec_k` data packets
produces `fec_n - fec_k` parity packets. `fec_timeout` (ms) force-closes a
partial block after that many milliseconds; `0` disables it.

MAVLink and the tunnel use `fec_k=1, fec_n=2` — every packet immediately
duplicated with one parity packet, no wait for a block to fill. Video uses
`fec_k=8, fec_n=12` (50% overhead), amortized over a higher-rate stream
where filling a block takes milliseconds.

## Video bandwidth budget

`50-config.sh` checks this automatically at install time when
`VIDEO_ENABLE=1`: `VIDEO_BITRATE_KBPS` inflated by `FEC_VIDEO_N/FEC_VIDEO_K`
against 40% of nominal PHY at the current `MCS_INDEX`/`BANDWIDTH`. The 40%
factor accounts for 802.11 injection overhead beyond FEC (no retries,
radiotap/802.11 headers, inter-frame gaps) and for MAVLink/tunnel sharing
the same airtime; real achievable throughput is roughly a third to a half
of nominal PHY, matching this factor. A failing check is a warning, not a
hard stop — install proceeds.

With the defaults (`VIDEO_BITRATE_KBPS=2000`, `FEC_VIDEO_N=12`,
`FEC_VIDEO_K=8` — 3000 kbps on air):

| MCS/bandwidth | Nominal PHY | 40% threshold | 2000 kbps camera |
|---|---|---|---|
| MCS1 / 20 MHz | 13 Mbit/s | 5200 kbps | Fits |
| MCS1 / 10 MHz | 6.5 Mbit/s | 2600 kbps | Exceeds |
| MCS3 / 10 MHz | 13 Mbit/s | 5200 kbps | Fits |

Going narrowband (10 MHz) for range while running video at 2000 kbps
requires raising `MCS_INDEX` (less range) or lowering `VIDEO_BITRATE_KBPS`.
