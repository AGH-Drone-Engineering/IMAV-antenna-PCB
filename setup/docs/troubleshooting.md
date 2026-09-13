# Troubleshooting: symptom → cause → command

Run `sudo ./scripts/wfb-doctor` first — as root, so its DKMS/`ethtool`
checks aren't silently skipped. It covers driver binding, package/service
state, tunnel presence, and live stream stats; the entries below are for
once you know roughly where the problem is.

## Index

- [Kernel headers won't install](#could-not-obtain-kernel-headers-in-stage-20-headers)
- [Driver build fails](#driver-build-fails-dkms-build-errors-out-in-stage-30-driver)
- [Driver missing after a kernel update](#after-an-apt-upgrade-that-touched-the-kernel)
- [`iw` "Device or resource busy"](#iw-returns--16-device-or-resource-busy-when-setting-the-channelmonitor-mode)
- [Radio comes up but no packets move](#no-packets-at-all--wfb-cli-shows-nothing-moving-on-either-end)
- [`sess` climbs, `udp` stays zero](#wfb-cli-shows-sess-climbing-but-udp-stays-at-zero)
- [`Unsupported peer address`](#unsupported-peer-address-in-the-journal-at-startup)
- [No `drone-wfb`/`gs-wfb` interface](#no-drone-wfbgs-wfb-interface-at-all-not-just-down--genuinely-absent)
- [Power: resets, drops, USB errors](#pi-resets-under-load-the-link-drops-when-it-shouldnt-usb-errors-show-up-in-dmesg)
- [Wrong RSSI in QGroundControl](#rssi-panel-in-qgroundcontrol-looks-wrongerratic)
- [Video service restart-looping](#wfb-video-airservice-keeps-restart-looping)
- [`VIDEO_SOURCE` has no matching module](#video_source--has-no-matching-module-at-install-time)
- [Choppy video / `trunc`](#video-is-choppy-or-wfb-cli-reports-trunc-on-the-video-stream)
- [Ground station won't accept the video stream](#ground-stations-rtspcodec-wont-accept-the-stream--stays-empty)

---

## Driver / DKMS

### `Could not obtain kernel headers` in stage `20-headers`

None of the candidate header packages for this platform installed a
working `/lib/modules/$(uname -r)/build`. Usually means the running
kernel is newer than the header package apt currently offers (a recent
`apt upgrade` that pulled a new kernel but not matching headers yet, or a
non-Raspberry-Pi-OS image with a different kernel/header split).

```sh
apt-cache search linux-headers   # see what's actually available
uname -r                         # compare against the package versions offered
```

Installing a matching `linux-headers-<exact-version>` package by hand,
or rebooting into a kernel version apt does have headers for, unblocks
this. Re-run: `sudo ./install.sh --role air|gs --only 20-headers`.

### Driver build fails (`dkms build` errors out in stage `30-driver`)

The single highest-risk stage in the installer — an out-of-tree kernel
module against whatever kernel your image ships.

1. Check `/var/lib/dkms/<package>/<version>/build/make.log` for the
   actual compiler error.
2. A `set_monitor_channel`/`net_device` signature mismatch means the
   pinned commit in `VERSIONS` is behind what your kernel needs — check
   for a newer commit on `libc0607/rtl88x2eu-20230815` branch `v5.15.0.1`.
3. Fallback: `VERSIONS` documents an older pin (`svpcom/rtl8812eu`) and
   Bookworm as a documented-working alternative OS if Trixie's kernel is
   the problem.

### After an `apt upgrade` that touched the kernel

An out-of-tree DKMS module does not automatically exist for a kernel it
hasn't been built against.

```sh
dkms status   # the running kernel must be listed as "installed", not "added" or missing
```

If missing: `sudo ./install.sh --role air|gs --only 30-driver
--force-driver`. Do this before flying, not after finding the link dead
in the field.

### `iw` returns `-16 Device or resource busy` when setting the channel/monitor mode

Monitor mode was set via the legacy WEXT ioctl path (`iwconfig`) instead
of cfg80211 (`iw`) — usually something else touched the interface first.

```sh
ip link set <iface> down
iw dev <iface> set monitor otherbss
ip link set <iface> up
iw dev <iface> set channel 165 HT20
```

wfb-ng does this itself at every start, by design. If it's still failing,
confirm NetworkManager isn't fighting it: check
`/etc/NetworkManager/conf.d/99-wfb-unmanaged.conf` is present and `nmcli
device status` shows the card as `unmanaged`.

## Link / keys

### No packets at all — `wfb-cli` shows nothing moving on either end

Usually a mismatched `wifi_channel`/`bandwidth`/`link_domain` between the
two ends, or different wfb-ng versions.

```sh
# compare on both ends -- must be identical:
grep -E 'wifi_channel|link_domain' /etc/wifibroadcast.cfg
dpkg -l wfb-ng | tail -1
```

The radio-section fingerprint `install.sh` prints after stage
`50-config` catches the first case at install or reconfigure time — if
it differs between the two hosts, `link.conf`/`link.conf.local` differ
in one of the RADIO settings.

### `wfb-cli` shows `sess` climbing but `udp` stays at zero

Mismatched keys — the two ends don't have a matching `drone.key`/`gs.key`
pair, most often because `wfb_keygen` was run a second time on one end
after the pair was already distributed (it silently invalidates the
other half; no error, just this symptom). `d_err`/`dec_err` climbing in
`wfb-cli`/`wfb-doctor`'s stream stats is the same underlying cause.

Regenerate on ONE host and re-provision:
`sudo ./scripts/wfb-keys-provision --role air|gs <peer-host>`.

### `Unsupported peer address` in the journal at startup

`MAVLINK_SERIAL` (or a manually-edited peer line) contains a `.` or `:`
in the device path — wfb-ng's `serial:` transport regex excludes both.
Classic trigger: pointing it at `/dev/serial/by-id/usb-...` instead of a
plain device path or a short udev symlink.

### No `drone-wfb`/`gs-wfb` interface at all (not just down — genuinely absent)

`wfb_tun` does not ship in wfb-ng's `.deb` (confirmed on real hardware).
`lib/40-wfb-ng.sh` handles this automatically at install time: it detects
the gap, reads the exact commit the installed package was built from (out
of its own `site.cfg`), and builds/installs `wfb_tun` from that same
commit. If the interface is still missing after a normal install:

```sh
command -v wfb_tun && wfb_tun --help   # should show a WFB-ng version line
dpkg -L wfb-ng | grep wfb_tun          # empty is expected/normal
```

If `wfb_tun` genuinely isn't there, re-run `sudo ./install.sh --role
air|gs --only 40-wfb-ng` and read the build output — `libevent-dev`
missing or a network hiccup during the clone are the two realistic
failure modes.

If that stage instead dies with `Could not locate wfb-ng's site.cfg`
(the installed package's own build-commit record is missing or was
moved), build `wfb_tun` by hand from whatever commit matches the
installed `wfb-ng` version:

```sh
dpkg -l wfb-ng | tail -1                          # installed version
sudo apt-get install -y libevent-dev
git clone https://github.com/svpcom/wfb-ng.git /tmp/wfb-ng-src
cd /tmp/wfb-ng-src && git checkout <matching tag/commit> && make wfb_tun
sudo install -m 0755 wfb_tun /usr/bin/wfb_tun
```

## Power

### Pi resets under load, the link drops when it shouldn't, USB errors show up in `dmesg`

Suspect power, not software, especially with `POWER_SOURCE=usb-pi`. A
Raspberry Pi's USB budget is below what this module draws at useful TX
power (numbers: `docs/tuning.md`), and there's no published curve mapping
`WIFI_TXPOWER` to current draw, so "just lower the power a bit" isn't a
verifiable fix. Move to a powered USB hub, a separate 5V rail, or the
carrier board's battery/BEC leads (`POWER_SOURCE=hub` or `external` in
`link.conf`).

## MAVLink

### RSSI panel in QGroundControl looks wrong/erratic

Check `mavlink_sys_id` (`MAVLINK_SYS_ID` in `link.conf`) isn't colliding
with something else on the same MAVLink network — only relevant once
more than one link feeds a single QGC instance.

## Video

### `wfb-video-air.service` keeps restart-looping

Normal and expected until `VIDEO_CAM_URL` points at a real, reachable
camera — `Restart=on-failure` just keeps trying. Confirm that's actually
the cause, and get the real error instead of digging through
`journalctl`:

```sh
sudo /usr/local/bin/wfb-video-air
```

Common message with no camera connected (or a wrong/unreachable
`VIDEO_CAM_URL`): GStreamer's `Could not open resource for reading and
writing. Failed to connect. (Timeout while waiting for server
response)`. Once the camera answers, the loop stops on its own.

### `VIDEO_SOURCE='...' has no matching module` at install time

Typo in `link.conf`, or a source that hasn't been implemented (only
`rtsp` ships — see `docs/integration.md`). The error message lists what's
actually available in `config/video-sources/`.

### Video is choppy, or `wfb-cli` reports `trunc` on the video stream

Two different causes:

- `trunc` means a payload exceeded wfb-ng's `radio_mtu` (1445) — the
  shipped `rtsp` pipeline's `mtu=1400` avoids this; a custom source
  module needs the same care.
- Choppy without `trunc` is an airtime budget problem:
  `VIDEO_BITRATE_KBPS` (inflated by `FEC_VIDEO_N`/`FEC_VIDEO_K` overhead)
  is too high for the current `BANDWIDTH`/`MCS_INDEX`. `50-config.sh`
  warns about this automatically — re-run `--only 50-config` and read
  the warning, or see `docs/tuning.md` for the numbers behind it.

### Ground station's `rtsp@<codec>` won't accept the stream / stays empty

`VIDEO_CODEC` must be identical on both ends — the air side picks
depay/parse/pay GStreamer elements by this value, the ground station
picks which `rtsp@` systemd instance to enable. `h265` on one end and
`h264` on the other means the gs side is running the wrong decoder for
what's actually arriving.
