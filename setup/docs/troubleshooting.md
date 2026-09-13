# Troubleshooting: symptom → cause → command

Run `./scripts/wfb-doctor` first — it runs most of the checks below in one
shot. This file is for once you know roughly where the problem is.

---

**`wfb-cli` shows `sess` climbing but `udp` stays at zero.**
→ Mismatched keys. The two ends don't have a matching `drone.key`/`gs.key`
pair — most often because `wfb_keygen` was run a second time on one end
after the pair was already distributed (it silently invalidates the other
half; there's no error, just this symptom).
```sh
sha256sum /etc/drone.key /etc/gs.key   # run on both ends, compare
```
If they don't look like a matched set, regenerate on ONE host and
re-provision: `./scripts/wfb-keys-provision --role air|gs <peer-host>`.

---

**No packets at all — `wfb-cli` shows nothing moving on either end.**
→ Usually one of: mismatched `wifi_channel`/`bandwidth`/`link_domain`
between the two ends, or different wfb-ng versions.
```sh
# compare on both ends -- must be identical:
grep -E 'wifi_channel|link_domain' /etc/wifibroadcast.cfg
dpkg -l wfb-ng | tail -1
```
The "radio-section fingerprint" line install.sh prints after `50-config` is
meant to catch the first case at install time — if it differs between the
two hosts, the config differs.

---

**`iw` returns `-16 Device or resource busy` when setting the channel/monitor mode.**
→ Monitor mode was set via the legacy WEXT ioctl path (`iwconfig`) instead
of cfg80211 (`iw`) — usually means something else touched the interface
first. Bring it down and set it explicitly:
```sh
ip link set <iface> down
iw dev <iface> set monitor otherbss
ip link set <iface> up
iw dev <iface> set channel 165 HT20
```
If wfb-ng is the one doing this at every start (it is, by design), and it's
still failing, check that NetworkManager isn't fighting it — confirm
`/etc/NetworkManager/conf.d/99-wfb-unmanaged.conf` is present and
`nmcli device status` shows the card as `unmanaged`.

---

**`Unsupported peer address` in the journal at startup.**
→ `MAVLINK_SERIAL` (or a manually-edited peer line) contains a `.` or `:`
in the device path. wfb-ng's `serial:` transport regex explicitly excludes
both. Classic trigger: pointing it at `/dev/serial/by-id/usb-...` instead of
a plain device path or a short udev symlink.

---

**Pi resets under load, the link drops when it shouldn't, USB errors show up in `dmesg`.**
→ Suspect **power**, not software, especially if `POWER_SOURCE=usb-pi`. A
Raspberry Pi's total USB budget (1.2–1.6 A across every port, depending on
model and PSU) is comfortably below what this module can draw at real TX
power, and there's no published figure mapping wfb-ng's `wifi_txpower`
scale to actual current draw — so "just lower the power a bit" is not a
verifiable fix. Move to a powered USB hub, a separate 5V rail, or the
carrier board's battery/BEC leads (`POWER_SOURCE=hub` or `external` in
`link.conf`).

---

**No `drone-wfb`/`gs-wfb` interface at all (not just down — genuinely absent).**
→ `wfb_tun` may not actually be installed. It's built by the driver's
Makefile but, as of this writing, isn't listed in wfb-ng's own packaging
metadata — meaning it's not guaranteed to ship in the `.deb`.
```sh
dpkg -L wfb-ng | grep wfb_tun
```
If that's empty: build `wfb_tun` from the wfb-ng source tree yourself and
install the binary to `/usr/bin/wfb_tun` (matching what the rest of the
package expects), then restart the service.

---

**Driver fails to build (`dkms build` errors out in stage 30-driver).**
→ This is the single highest-risk stage in the whole installer — an
out-of-tree kernel module against whatever kernel your image ships.
1. Check `/var/lib/dkms/<package>/<version>/build/make.log` for the actual
   compiler error.
2. If it's a `set_monitor_channel`/`net_device` signature mismatch: the
   pinned commit in `VERSIONS` may be behind what your kernel needs. Check
   for a newer commit on `libc0607/rtl88x2eu-20230815` branch `v5.15.0.1`.
3. As a fallback, `VERSIONS` documents an older pin (`svpcom/rtl8812eu`) and
   Bookworm as a documented-working alternative OS if Trixie's kernel is
   the problem.

---

**After an `apt upgrade` that touched the kernel.**
→ The DKMS module doesn't automatically exist for a kernel it hasn't been
built against yet.
```sh
dkms status   # check the running kernel is listed as "installed", not "added" or missing entirely
```
If it's missing for the new kernel: `sudo ./install.sh --role air|gs --only
30-driver --force-driver`. Do this **before** flying, not after noticing the
link is dead on the field.

---

**RSSI panel in QGroundControl looks wrong/erratic.**
→ Check `mavlink_sys_id` in the generated config isn't colliding with
something else on the same MAVLink network (only relevant once you have
more than one link feeding one QGC instance — not an MVP concern with a
single drone/single ground station, but worth knowing if you add a second
link later).
