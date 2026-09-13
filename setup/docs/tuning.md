# Tuning: bandwidth, power, antennas, and the legal picture

## MCS and channel width — the range/rate tradeoff

Rates for HT (802.11n), 1 spatial stream, long guard interval (this
hardware's actual operating mode — 2T2R with STBC, not multi-stream):

| MCS | 20 MHz | 10 MHz | Notes |
|---|---|---|---|
| 0 | 6.5 Mbit/s | 3.25 Mbit/s | BPSK 1/2 — most robust |
| **1** | **13 Mbit/s** | **6.5 Mbit/s** | QPSK 1/2 — **the default here**, range/rate sweet spot |
| 2 | 19.5 Mbit/s | 9.75 Mbit/s | QPSK 3/4 |
| 3 | 26 Mbit/s | 13 Mbit/s | 16-QAM 1/2 — realistic ceiling for video at range |
| 4-7 | 39-65 Mbit/s | 19.5-32.5 Mbit/s | Short range only |

Each MCS step costs roughly 3-5 dB of link budget. `short_gi=True` would add
~11% rate but reduces tolerance to multipath — left `False` here on purpose,
since ground-reflection multipath is exactly what a long link over open
terrain has to deal with.

**20 MHz vs 10 MHz:** halving the channel width halves the receiver noise
floor (~3 dB less thermal noise in the pass-band) — roughly +3 dB of link
budget, ~1.4× range at the same MCS, at half the PHY rate. Bring the link up
at 20 MHz first (fewer unknowns while you're proving everything else
works), then switch both ends to 10 MHz once it's solid and re-measure.
**5 MHz and 40 MHz are both disallowed** by this installer: 5 MHz crashes
`wfb_tx` outright (`Unsupported HT bandwidth: 5`), and 40 MHz has a known
firmware injection instability on this chipset.

**Bitrate budget, concretely:** at MCS1/10 MHz, 6.5 Mbit/s PHY, halved again
by the 1:1 FEC redundancy on the MAVLink and tunnel streams, leaves roughly
2-3 Mbit/s of real headroom. MAVLink telemetry is a few tens of kbit/s, so
SSH + MAVLink alone isn't within an order of magnitude of that ceiling — the
spare capacity is exactly what video needs to fit into. See "Video bandwidth
budget" below for the concrete numbers.

## TX power

`wifi_txpower` for this chipset is **dBm × 100, positive** (8812au uses
negative values for the same field — don't mix them up, and don't confuse
either with OpenIPC's unrelated 0-63 `driver_txpower_override` scale used
in a different stack's config file). Roughly +5 dB per +500. The power
amplifier begins saturating around 2000 — above that you're converting
battery capacity into heat and spectral splatter, not range, and a
saturating PA can *reduce* effective range by degrading the signal
constellation rather than improving it.

The driver author's own description of this value: "some internal,
dimensionless value, only positively related to the real TX power" — it is
not a calibrated dBm figure, and there is no published curve mapping it to
actual current draw. Treat every power number here as relative, not
absolute.

See `link.conf`'s `POWER_SOURCE`/`WIFI_TXPOWER` section for the concrete
ladder and the installer-enforced ceilings (`TXPOWER_MAX_USB` /
`TXPOWER_MAX_EXTERNAL`) — that's the operative safety mechanism, this
section is the reasoning behind the numbers.

## Antennas dominate everything else

This card is 2T2R with two IPEX antenna ports. Going from a pair of ~2 dBi
stub antennas to a pair of ~5 dBi dipoles on **both** ends is +6 dB of link
budget — roughly a doubling of range — which no amount of MCS/bandwidth/FEC
tuning will match. On the ground, a patch or panel antenna (8-14 dBi) buys
even more, at the cost of needing to point it at the aircraft; that's
genuinely where multi-kilometer range comes from, not radio settings.

Mount the drone's two antennas with some angular separation (not parallel)
for polarization diversity — `wfb-cli`'s per-antenna RSSI columns are your
antenna-health indicator: a >10 dB gap between the two columns on a card
that should be seeing the same signal usually means a bad connector or a
damaged antenna, not a real propagation difference.

## FEC vs latency

`fec_k`/`fec_n` are block erasure coding: `wfb_tx` can't emit parity until a
block of `k` data packets is full, so a sparse stream (like MAVLink) can sit
waiting for a block to close. That's why `fec_timeout` exists — it force-
closes a partial block after N milliseconds so a single heartbeat packet
doesn't get stuck. The MVP defaults (`fec_k=1, fec_n=2` — 100% redundancy —
for both MAVLink and the tunnel) mean every packet is immediately
duplicated with one parity packet: no waiting, maximum robustness, and the
overhead is irrelevant at these bitrates. Video uses `fec_k=8, fec_n=12`
instead — 50% overhead amortized over a much higher-rate stream, where
waiting a few packets for a block to fill costs microseconds, not
noticeable latency. There's deliberately no `FEC_VIDEO_TIMEOUT`: unlike the
sparse MAVLink/tunnel streams, video fills a 12-packet block in
milliseconds at any real bitrate, so there's nothing to force-close.

## Video bandwidth budget

`50-config.sh` checks this automatically at install time (a warning, not a
hard stop) whenever `VIDEO_ENABLE=1`, because a camera bitrate that was
never sized against the actual radio settings is one of the hardest things
to diagnose after the fact — it just looks like "video breaks up
sometimes," which could be a dozen other things.

The check: `VIDEO_BITRATE_KBPS × FEC_VIDEO_N / FEC_VIDEO_K` (the camera's
bitrate inflated by FEC overhead — what the radio actually has to carry)
against 40% of the nominal PHY rate for the current `MCS_INDEX`/`BANDWIDTH`
(the MCS table above). That 40% is a **conservative rule of thumb, not a
calibrated link model** — FEC overhead is already counted separately above,
so this factor stands in for everything else raw 802.11 injection doesn't
give you for free (no retries, radiotap/802.11 header overhead, inter-frame
gaps), plus the fact that MAVLink and the SSH tunnel are sharing the same
airtime. Real achievable throughput depends on distance, antennas, and
interference, none of which the installer can know — treat a passing check
as "should be in the right neighborhood," not a guarantee, and a failing
one as "almost certainly won't work," not just a stylistic warning.

Concretely, with the defaults (`VIDEO_BITRATE_KBPS=2000`, `FEC_VIDEO_N=12`,
`FEC_VIDEO_K=8` → ~3000 kbps on air):

| MCS/bandwidth | Nominal PHY | 40% threshold | 2000 kbps camera fits? |
|---|---|---|---|
| MCS1 / 20 MHz | 13 Mbit/s | 5200 kbps | Yes |
| MCS1 / 10 MHz | 6.5 Mbit/s | 2600 kbps | **No** — this is the long-range setting the rest of this doc recommends, and it doesn't have room for a 2 Mbit/s camera stream at MCS1 |
| MCS3 / 10 MHz | 13 Mbit/s | 5200 kbps | Yes |

So going narrowband for range (10 MHz) and running video at the same time
means either raising `MCS_INDEX` (less range, matching the MCS3/10MHz row
above) or lowering `VIDEO_BITRATE_KBPS` to fit MCS1's smaller budget — not
both defaults at once. There's no universally correct answer here; it's a
real tradeoff between range and video quality that depends on what the
mission actually needs, which is why this is a warning you make a call on,
not a value the installer picks for you.

## The legal picture — read this before transmitting at real power

**Channel 165 (5825 MHz) is not EU-harmonised for general RLAN use.**
5470-5725 MHz is the EU-harmonised band (up to 1 W EIRP under EN 301 893,
with DFS/TPC requirements); 5725-5850 MHz — where channel 165 lives, and
where the FPV community's usual "5.8 GHz" convention comes from — falls
under Annex B of that same standard, explicitly marked "subject to national
frequency conditions." In Poland that generally means it is **not**
available for general-purpose WiFi use without separate authorization.

Setting `wifi_region = 'BO'` (the value wfb-ng's own defaults use) lifts the
**driver's own** channel/power/DFS restrictions. It does not create legal
authorization to transmit — that's a completely separate question, and one
this installer has no way to resolve for you. Routes that do: a frequency
assignment from UKE, an amateur radio license (which carries a secondary
allocation overlapping part of this range), or an event organizer's
specific frequency coordination (relevant for competition contexts).

Resolve this before transmitting at anything beyond the low, bench-testing
power levels this installer defaults to.
