# Connecting to the link: SSH, MAVLink, and video

## The basics — this is not a WiFi network

The BL-M8812EU2 cards run in monitor mode and inject raw 802.11 frames. No
access point, no association, no DHCP. wfb-ng multiplexes everything into
a fixed set of streams, each exposed on both ends as a plain UDP socket on
localhost (or, for the tunnel, a network interface):

| Stream | Air unit | Ground station |
|---|---|---|
| MAVLink | opens `/dev/serial0` (or listens on a UDP port) | `connect://127.0.0.1:14550` by default |
| Tunnel (SSH etc.) | `drone-wfb` interface, `10.5.0.2/24` | `gs-wfb` interface, `10.5.0.1/24` |
| Video | source module feeds `udp://127.0.0.1:5602` | forwards to `udp://127.0.0.1:5600`, optionally re-served as RTSP |

## SSH

```sh
ssh pi@10.5.0.2      # from the ground station, to the drone
ssh <user>@10.5.0.1  # from the drone, to the ground station
```

Constraint: this tunnel runs 100% FEC redundancy with a short aggregation
timeout, tuned for a responsive interactive session, not throughput. Move
large files over `wlan0`/Ethernet before or after the flight instead.

`.local` hostnames do not resolve over this tunnel — use the IP addresses
above. The tunnel interfaces are point-to-point (`ip link show drone-wfb`
reports `POINTOPOINT`), and avahi's default config does not advertise mDNS
over point-to-point interfaces. Reaching a Pi as `hostname.local` during
bring-up is resolving over `wlan0`/Ethernet, which stops working once the
drone is out of range of that network — every real flight.

If `ssh` times out, check `ip -brief addr show` for `drone-wfb`/`gs-wfb`
on both ends first — see `docs/troubleshooting.md` if either is absent.

## MAVLink

Wiring: flight controller TELEM UART → Pi GPIO14 (TXD)/GPIO15 (RXD) + GND
→ `/dev/serial0` → wfb-ng's native `serial:` transport → ground station →
UDP `127.0.0.1:14550` → QGroundControl / Mission Planner. `install.sh`'s
`80-payload` stage enables the Pi's UART and removes the kernel's login
console from it — otherwise both the console and the flight controller
transmit on the same wire.

Constraint: `MAVLINK_SERIAL` rejects any path containing `.` or `:` — a
`by-id` path such as `/dev/serial/by-id/usb-FTDI_...-if00-port0` fails
with `Unsupported peer address`. Use a udev symlink without dots
(`/dev/fc-serial`) if you need one independent of USB enumeration order.

MAVLink over UDP instead of a UART (companion computer, SITL): set
`MAVLINK_UDP_PORT` in `link.conf` (or `--mavlink-udp PORT`) — the air unit
listens on that port instead, `MAVLINK_SERIAL`/`MAVLINK_BAUD` are ignored.

Ground-station side: `QGC_HOST=127.0.0.1` (default) for QGC on the ground
station Pi itself; `QGC_HOST=<laptop-ip>` for QGC on a separate machine on
the LAN, with a matching UDP connection added in QGC pointing at the
ground station's LAN address, port 14550. After changing it: `sudo
./install.sh --role gs --only 50-config && sudo systemctl restart
wifibroadcast@gs`.

Verification: QGroundControl's RSSI/link-quality panel populates from
real link stats (`inject_rssi=True` in the generated config synthesizes
`RADIO_STATUS` messages from actual radio numbers, not just
connected/disconnected).

## Video

Constraint: never route RTSP through the IP tunnel. RTSP runs over TCP,
which responds to loss on a lossy radio link by retransmitting and
backing off — climbing multi-second latency on live video. Video has its
own FEC-protected UDP stream instead, entirely separate from the tunnel
and radio/FEC/MAVLink/SSH configuration: as soon as `wifibroadcast@drone`
is running, something is listening on `udp://127.0.0.1:5602` on the air
unit and the ground station is forwarding to `udp://127.0.0.1:5600`,
whether or not a source is plugged in.

`VIDEO_SOURCE` in `link.conf` selects a module from
`setup/config/video-sources/`. Only `rtsp` (an IP camera on Ethernet,
already emitting RTSP) ships. See that file's own comments for the module
contract if adding a `uvc` or `csi` source later — nothing in
`lib/90-video.sh` needs to change to add one.

### Setting up the `rtsp` source

In `link.conf`, on both ends:

```sh
VIDEO_ENABLE=1
VIDEO_SOURCE=rtsp
VIDEO_CAM_URL=rtsp://192.168.10.50:554/stream1   # the camera's real URL
VIDEO_CODEC=h265                                  # whatever the camera sends, both ends
```

Then, on each host:

```sh
sudo ./install.sh --role air --only 90-video    # drone
sudo ./install.sh --role gs  --only 90-video    # ground station
```

The camera and the Pi need a static IP each on the same subnet — there is
no DHCP server on a point-to-point Ethernet link, and the installer does
not touch `eth0`. On the air unit:

```sh
sudo nmcli con add type ethernet ifname eth0 con-name camera \
  ipv4.method manual ipv4.addresses 192.168.10.1/24 connection.autoconnect yes
```

Set a matching static address in the camera's own configuration. Do not
use `10.5.0.0/24` for this — that range is the wfb-ng tunnel's own
(`TUNNEL_IP_AIR`/`TUNNEL_IP_GS` in `link.conf`).

### Viewing the stream on the ground

With `VIDEO_RTSP_SERVER=1` (default): `rtsp://<ground-station-ip>:8554/wfb`
in any RTSP-capable player or QGroundControl's video settings, any number
of concurrent viewers. With `VIDEO_RTSP_SERVER=0`: read RTP directly off
`udp://127.0.0.1:5600` on the ground station (a `gst-launch-1.0
udpsrc port=5600 ! ...` pipeline, or QGC pointed at that UDP port) — lower
latency, one viewer.

### If the pipeline won't come up

```sh
sudo systemctl status wfb-video-air
sudo journalctl -u wfb-video-air -e --no-pager
sudo /usr/local/bin/wfb-video-air        # run it directly for the real GStreamer error
```

`Could not open resource for reading and writing. Failed to connect.
(Timeout while waiting for server response)` is expected until
`VIDEO_CAM_URL` points at a real, reachable camera — `Restart=on-failure`
keeps retrying, so plugging the camera in later brings video up without
re-running anything.

Video bandwidth budget and MCS/bandwidth tradeoffs: `docs/tuning.md`.
