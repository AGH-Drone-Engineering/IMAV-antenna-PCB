# Connecting to the link: SSH, MAVLink, and (later) video

## The basics — this is not a WiFi network

The BL-M8812EU2 cards run in monitor mode and inject raw 802.11 frames.
There's no access point, no association, no DHCP — you don't "connect to"
this link the way you'd join a WiFi network. wfb-ng instead multiplexes
everything into a small number of fixed streams, and each stream shows up on
**both ends as a plain UDP socket on localhost** (or, for the tunnel, as a
normal network interface). Whatever you point at those sockets doesn't need
to know wfb-ng exists underneath it.

| Stream | Air unit | Ground station |
|---|---|---|
| MAVLink | opens `/dev/serial0` (or listens on a UDP port) | `connect://127.0.0.1:14550` by default |
| Tunnel (SSH etc.) | `drone-wfb` interface, `10.5.0.2/24` | `gs-wfb` interface, `10.5.0.1/24` |
| Video (phase 2, not wired up yet) | listens on `udp://127.0.0.1:5602` | forwards to `udp://127.0.0.1:5600` |

## SSH

wfb-ng's tunnel stream creates a real network interface on each end —
`drone-wfb` (10.5.0.2/24) on the air unit, `gs-wfb` (10.5.0.1/24) on the
ground station, both on the same /24. That's it; there's nothing to
configure in `sshd` — it already listens on every interface.

```sh
# from the ground station:
ssh pi@10.5.0.2

# from the drone:
ssh <user>@10.5.0.1
```

**This tunnel is not a general-purpose network link.** It runs 100% FEC
redundancy and a short aggregation timeout to keep it responsive for
low-bandwidth, latency-sensitive traffic — that's right for an interactive
SSH session, wrong for `scp`-ing a large file or anything else that wants
throughput. If you need to move real data, do it before or after the flight
over `wlan0`/Ethernet, not over this tunnel.

If `ssh` times out: check `ip -brief addr show` for `drone-wfb`/`gs-wfb` on
both ends first — if the interface isn't there at all (not just down),
you're very likely missing `wfb_tun` in the package install (see
`docs/troubleshooting.md`), not looking at a network problem.

## MAVLink

Default wiring: flight controller's telemetry UART → Pi's `/dev/serial0` →
wfb-ng (native `serial:` transport — no `mavlink-routerd` or `socat` needed,
wfb-ng opens the device itself) → mavlink stream → ground station → UDP
`127.0.0.1:14550` → QGroundControl / Mission Planner.

Physical wiring: FC TELEM port ↔ Pi GPIO14 (TXD)/GPIO15 (RXD) + GND. The
installer's `80-payload` stage enables the Pi's UART (`enable_uart=1`) and
removes the kernel's login console from that same UART (otherwise both the
console and your flight controller are transmitting on the same wire).

**The one real trap in wfb-ng's serial peer syntax:** it rejects any device
path containing a `.` or `:` — so `/dev/serial/by-id/usb-FTDI_...-if00-port0`
will fail with `Unsupported peer address`, even though it looks like a
perfectly normal path. If you need a name that doesn't depend on USB
enumeration order, make a short udev symlink without dots in it (e.g.
`/dev/fc-serial`) and point `MAVLINK_SERIAL` at that instead.

**If your MAVLink source is a companion computer or SITL sending UDP
instead of a UART:** set `MAVLINK_UDP_PORT` in `link.conf` (or pass
`--mavlink-udp PORT` to `install.sh`) — the air unit will listen on that UDP
port instead of opening a serial device, and `MAVLINK_SERIAL`/`MAVLINK_BAUD`
are ignored.

**Ground-station side, three variants, one value to change:**

- QGC on the ground-station Pi itself (default): leave `QGC_HOST=127.0.0.1`.
- QGC on a separate laptop on the LAN: set `QGC_HOST=<laptop-ip>` in
  `link.conf`, then add a UDP connection in QGC pointing at the ground
  station's LAN address, port 14550.
- Either way, re-run `sudo ./install.sh --role gs --only 50-config &&
  sudo systemctl restart wifibroadcast@gs` after changing it.

**Verifying it works:** QGroundControl should show the vehicle connecting
on UDP 14550, and its RSSI/link-quality display should populate — wfb-ng
synthesizes `RADIO_STATUS` MAVLink messages from the actual link stats
(`inject_rssi = True` in the generated config), so that panel is showing
you real numbers from the radio link, not just "connected: yes/no".

## Video (not part of the MVP — this section is for when a camera is chosen)

**The one thing not to do: don't route RTSP through the IP tunnel.** RTSP
runs over TCP, and TCP over a lossy radio link responds to packet loss by
retransmitting and backing off — exactly wrong for live video, and you'll
see multi-second latency climb steadily worse. Use wfb-ng's own video
stream instead, which is FEC-protected UDP designed for exactly this.

The radio side of this is **already live and waiting**, even with no camera
plugged in: wfb-ng's own `[drone]`/`[gs]` profiles declare the video stream
unconditionally, so as soon as `wifibroadcast@drone` is running, something
is already listening on `udp://127.0.0.1:5602` on the air unit, and the
ground station is already forwarding whatever arrives on the matching
stream to `udp://127.0.0.1:5600`. Adding a camera is only steps 1-2 below —
nothing about the radio link/config changes.

1. **Air unit:** point an encoder at the video socket, without touching the
   video codec if you can avoid it (re-encoding costs Pi CPU and quality for
   no benefit — depay/repay instead):

   ```sh
   # (a) IP camera already emitting RTSP/H.265 -- repackage without re-encoding:
   gst-launch-1.0 -q rtspsrc location=<rtsp-url> latency=0 protocols=tcp \
     ! rtph265depay ! h265parse config-interval=1 ! rtph265pay pt=97 mtu=1400 config-interval=1 \
     ! udpsink host=127.0.0.1 port=5602 sync=false

   # (b) USB/UVC or HDMI-to-USB capture -- has to be encoded on the Pi:
   gst-launch-1.0 -q v4l2src device=/dev/video0 ! videoconvert \
     ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 \
     ! rtph264pay pt=96 mtu=1400 config-interval=1 ! udpsink host=127.0.0.1 port=5602 sync=false

   # (c) Raspberry Pi CSI camera:
   rpicam-vid -t 0 --inline --nopreview --codec h264 --width 1280 --height 720 \
     --framerate 30 --bitrate 2000000 -o - \
     | gst-launch-1.0 -q fdsrc ! h264parse config-interval=1 \
       ! rtph264pay pt=96 mtu=1400 config-interval=1 ! udpsink host=127.0.0.1 port=5602 sync=false
   ```

   **`mtu=1400` is not arbitrary** — wfb-ng's `radio_mtu` is 1445; go over it
   and `wfb-cli` will start reporting `trunc` on that stream.

2. **Ground station:** either read RTP directly off `udp://127.0.0.1:5600`
   (most players/QGC can do this), or re-serve it as RTSP for multiple
   viewers using wfb-ng's own shipped unit: `sudo systemctl enable --now
   rtsp@h265` → `rtsp://<ground-station>:8554/wfb`.

3. Revisit `BANDWIDTH`/`MCS_INDEX` once video is flowing — MAVLink+SSH alone
   use a tiny fraction of even a 10 MHz link's capacity; video is what
   actually needs the bitrate budget. See `docs/tuning.md`.
