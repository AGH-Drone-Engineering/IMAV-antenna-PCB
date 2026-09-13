#!/usr/bin/env bash
# setup/config/video-sources/rtsp.sh — video source module for an IP camera
# on Ethernet, already emitting RTSP. Loaded (sourced) by
# setup/lib/90-video.sh when VIDEO_SOURCE=rtsp; only air-role config reads
# this file (the gs side doesn't need a source module at all).
#
# MODULE CONTRACT — every video-sources/*.sh must define exactly these three
# functions, and nothing else is required of it:
#
#   video_src_packages()  echo the space-separated apt package list this
#                         source needs. Only installed when this source is
#                         actually selected, so e.g. a future csi.sh's
#                         rpicam-apps never lands on a host using rtsp.
#   video_src_validate()  die with a clear message if this source's own
#                         link.conf settings are missing/wrong (e.g. rtsp
#                         needs VIDEO_CAM_URL). Called before anything is
#                         installed or written.
#   video_src_pipeline()  echo the complete shell command line that reads
#                         from this source and writes RTP to
#                         udp://127.0.0.1:5602 -- that socket is where
#                         wfb-ng's own [drone] profile is already listening
#                         unconditionally, so this is the ONLY contract a
#                         source has to satisfy. Radio/FEC/tunnel config
#                         never changes based on which source is selected.
#
# To add a USB/HDMI capture card or a Pi CSI camera later: copy this file to
# uvc.sh/csi.sh, implement the same three functions, set VIDEO_SOURCE
# accordingly in link.conf. Nothing in lib/90-video.sh, the systemd unit, or
# any other file needs to change -- the dispatcher finds modules by name.

video_src_packages() {
    echo "gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad"
}

video_src_validate() {
    [ -n "$VIDEO_CAM_URL" ] || die "VIDEO_SOURCE=rtsp requires VIDEO_CAM_URL (e.g. rtsp://192.168.10.50:554/stream1) -- set it in link.conf."
    case "$VIDEO_CODEC" in
        h264|h265) ;;
        *) die "VIDEO_CODEC must be h264 or h265 for the rtsp source (got '$VIDEO_CODEC')." ;;
    esac
}

# Repackages the camera's existing RTP payload without re-encoding
# (depay -> parse -> pay, not decode -> encode): zero Pi CPU cost, zero
# quality loss. mtu=1400 is not arbitrary -- wfb-ng's radio_mtu is 1445;
# go over it and wfb-cli starts reporting `trunc` on the video stream.
video_src_pipeline() {
    local depay pay pt
    case "$VIDEO_CODEC" in
        h264) depay=rtph264depay; pay=rtph264pay; pt=96 ;;
        h265) depay=rtph265depay; pay=rtph265pay; pt=97 ;;
        *) die "video-sources/rtsp.sh: unsupported VIDEO_CODEC '$VIDEO_CODEC' (h264|h265)" ;;
    esac
    cat <<EOF
exec gst-launch-1.0 -q rtspsrc location='${VIDEO_CAM_URL}' latency=${VIDEO_RTSP_LATENCY} protocols=${VIDEO_RTSP_PROTOCOLS} \\
  ! ${depay} ! ${VIDEO_CODEC}parse config-interval=1 ! ${pay} pt=${pt} mtu=1400 config-interval=1 \\
  ! udpsink host=127.0.0.1 port=5602 sync=false
EOF
}
