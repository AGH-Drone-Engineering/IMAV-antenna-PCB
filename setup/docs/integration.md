# Connecting to the link: SSH, MAVLink, and video

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
| Video | source module feeds `udp://127.0.0.1:5602` | forwards to `udp://127.0.0.1:5600`, optionally re-served as RTSP |

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

**`.local` hostnames do not resolve over this tunnel — use the IP addresses.**
Verified directly in `avahi-daemon`'s own log: it explicitly withdraws mDNS
for the tunnel interface (`Withdrawing workstation service for drone-wfb`),
because that interface is point-to-point (`ip link show drone-wfb` reports
`POINTOPOINT`) and avahi's default config has `allow-point-to-point=no`. If
you've been reaching both Pis as `hostname.local` during bring-up, that's
resolving over `wlan0` (both on the same WiFi) or Ethernet — it will stop
working the moment the drone is somewhere `wlan0` can't reach, which is
every real flight. Always use `10.5.0.2` (air) / `10.5.0.1` (gs) for
anything that has to work over the radio link itself.

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

## Video

**The one thing not to do: don't route RTSP through the IP tunnel.** RTSP
runs over TCP, and TCP over a lossy radio link responds to packet loss by
retransmitting and backing off — exactly wrong for live video, and you'll
see multi-second latency climb steadily worse. This is why video has its
own stream, entirely separate from the tunnel: it's FEC-protected UDP
designed for exactly this, and it's already live and waiting even with no
camera plugged in. wfb-ng's own `[drone]`/`[gs]` profiles declare the video
stream unconditionally, so as soon as `wifibroadcast@drone` is running,
something is already listening on `udp://127.0.0.1:5602` on the air unit,
and the ground station is already forwarding whatever arrives on the
matching stream to `udp://127.0.0.1:5600`. **The radio/FEC/tunnel
configuration never changes because of anything in this section.**

### How video plugs in: a pluggable source, one stage

`VIDEO_SOURCE` in `link.conf` picks a file from
`setup/config/video-sources/<name>.sh`. Only `rtsp` (an IP camera on
Ethernet, already emitting RTSP) ships today. Setting up the radio side of a
camera is `setup/lib/90-video.sh` (stage `90-video`, run automatically as
part of a full install, or on its own via `--only 90-video`):

- **Air role:** loads the module for `VIDEO_SOURCE`, installs only the
  packages that source needs, generates `/usr/local/bin/wfb-video-air` (a
  plain script with the actual pipeline command baked in — deliberately a
  separate file rather than a command embedded in the systemd unit, so you
  can run it by hand and see the real GStreamer error instead of digging
  through `journalctl`), and enables it as `wfb-video-air.service`.
- **Ground station:** enables wfb-ng's own `rtsp@<codec>.service` (from the
  wfb-ng package — not reimplemented here) if `VIDEO_RTSP_SERVER=1`, giving
  you `rtsp://<ground-station>:8554/wfb` for any number of viewers. Set it
  to `0` and read RTP directly off `udp://127.0.0.1:5600` instead (most
  players, and QGC, can do this directly).

Nothing happens at all when `VIDEO_ENABLE=0` (the default) — no packages
installed, no units touched.

### Setting up the `rtsp` source (IP camera on Ethernet)

In `link.conf`, on **both** ends:

```sh
VIDEO_ENABLE=1
VIDEO_SOURCE=rtsp
VIDEO_CAM_URL=rtsp://192.168.10.50:554/stream1   # your camera's real URL
VIDEO_CODEC=h265                                  # whatever the camera sends
```

`VIDEO_CODEC` must match on both ends — the air side uses it to pick
GStreamer's depay/parse/pay elements, the ground station uses it to pick
which `rtsp@` instance to enable. Then, on each host:

```sh
sudo ./install.sh --role air --only 90-video    # on the drone
sudo ./install.sh --role gs  --only 90-video    # on the ground station
```

The generated pipeline **repackages the camera's existing bitstream without
re-encoding it** (depay → parse → pay, not decode → encode): zero Pi CPU
cost, zero quality loss. `mtu=1400` in that pipeline is not arbitrary —
wfb-ng's `radio_mtu` is 1445; go over it and `wfb-cli` starts reporting
`trunc` on the video stream.

**Getting the camera and the Pi onto the same subnet is on you, not the
installer.** There's no DHCP server on a point-to-point Ethernet link
between a camera and a Pi — both ends need a static address you set once.
On the air unit's `eth0`:

```sh
sudo nmcli con add type ethernet ifname eth0 con-name camera \
  ipv4.method manual ipv4.addresses 192.168.10.1/24 connection.autoconnect yes
```
(no gateway needed — it's a direct point-to-point link, not a route to anywhere else)

...and the matching static address on the camera's own web/app config
(check its manual — every camera does this differently). **Don't put that
subnet on `10.5.0.x`** — that's the wfb-ng tunnel's own address range
(`TUNNEL_IP_AIR`/`TUNNEL_IP_GS` in `link.conf`); overlapping it will break
routing to the camera in ways that are annoying to debug. `192.168.10.x`
(as above) or anything else outside `10.5.0.0/24` is fine. The installer
never touches `eth0` — this is the one manual, one-time step per host.

### Debugging a video pipeline that won't come up

```sh
sudo systemctl status wfb-video-air     # is it running, restart-looping?
sudo journalctl -u wfb-video-air -e --no-pager
sudo /usr/local/bin/wfb-video-air       # run it directly for the real error
```

The single most common message with no camera connected yet (or a wrong
`VIDEO_CAM_URL`) is GStreamer's own:
```
ERROR: from element .../GstRTSPSrc:rtspsrc0: Could not open resource for reading and writing.
Failed to connect. (Timeout while waiting for server response)
```
— that's expected until `VIDEO_CAM_URL` points at a real, reachable camera.
`Restart=on-failure` means the service keeps retrying every few seconds, so
plugging the camera in later brings video up without re-running anything.

### Adding a USB/HDMI (`uvc`) or Pi Camera (`csi`) source later

Neither ships today, but the structure is built for them. A source module
is exactly three shell functions — copy `setup/config/video-sources/rtsp.sh`
as a starting point:

```sh
video_src_packages()  { echo "..."; }   # space-separated apt packages this source needs
video_src_validate()  { ...; }          # die with a clear message if this source's
                                         # own link.conf settings are missing/wrong
video_src_pipeline()  { echo "..."; }   # the complete command that writes RTP to
                                         # udp://127.0.0.1:5602 -- the only contract
```

Save it as `config/video-sources/uvc.sh` (or `csi.sh`), set
`VIDEO_SOURCE=uvc` in `link.conf`, done — nothing in `lib/90-video.sh`, the
systemd unit, or anywhere else needs to change. `VIDEO_DEV`,
`VIDEO_WIDTH`/`HEIGHT`/`FPS` already exist in `link.conf` for exactly this
(unused by `rtsp`, which doesn't capture/encode anything itself). Starting
points for the actual pipelines:

```sh
# USB/UVC or HDMI-to-USB capture -- has to be encoded on the Pi:
gst-launch-1.0 -q v4l2src device=${VIDEO_DEV} ! videoconvert \
  ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=${VIDEO_BITRATE_KBPS} key-int-max=30 \
  ! rtph264pay pt=96 mtu=1400 config-interval=1 ! udpsink host=127.0.0.1 port=5602 sync=false

# Raspberry Pi CSI camera:
rpicam-vid -t 0 --inline --nopreview --codec h264 --width ${VIDEO_WIDTH} --height ${VIDEO_HEIGHT} \
  --framerate ${VIDEO_FPS} --bitrate $((VIDEO_BITRATE_KBPS * 1000)) -o - \
  | gst-launch-1.0 -q fdsrc ! h264parse config-interval=1 \
    ! rtph264pay pt=96 mtu=1400 config-interval=1 ! udpsink host=127.0.0.1 port=5602 sync=false
```

### Bandwidth

Revisit `BANDWIDTH`/`MCS_INDEX` once video is flowing — MAVLink+SSH alone
use a tiny fraction of even a 10 MHz link's capacity; video is what
actually needs the bitrate budget, and `VIDEO_BITRATE_KBPS` needs to be
sized against it. The installer checks this automatically at `--only
50-config` time (a warning, not a hard stop) — see `docs/tuning.md` for the
numbers behind it.
