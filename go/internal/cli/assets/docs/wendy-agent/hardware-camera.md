# Camera Access

Camera access is used for webcam streaming, computer vision, image capture, and ML inference pipelines. Wendy apps cannot open `/dev/video*` unless the app declares a camera entitlement.

Add the entitlement from the project directory:

```bash
wendy project entitlements add camera
```

The older `video` entitlement is still accepted for compatibility, but new projects should use `camera`.

## Device Commands

Camera device inspection and streaming currently live under `wendy device video`:

```bash
wendy device video list
wendy device video stream --id 0
wendy device video stream --id 0 --width 1280 --height 720 --fps 30
wendy device video stream --id 0 --stdout
```

For generic capability inspection:

```bash
wendy device hardware list --category camera
```

## PipeWire Camera Sharing

WendyOS routes V4L2 cameras through PipeWire, enabling multiple processes to open the same camera simultaneously without receiving a `EBUSY` error. The `pipewire-v4l2` compatibility shim intercepts V4L2 API calls from applications that use `/dev/video*` directly and redirects them through PipeWire transparently.

Because WendyOS devices have no display server or logind seat, WirePlumber requires explicit configuration to enumerate cameras. The file `/etc/wireplumber/wireplumber.conf.d/60-wireplumber-camera-headless.conf` marks the `monitor.v4l2` component as `required` in WirePlumber's main profile, ensuring cameras are always discovered regardless of seat presence. Camera nodes are visible in `wpctl status` once WirePlumber is running as the `wendy` user.

## GStreamer Support

WendyOS includes a full GStreamer stack for camera streaming pipelines. The following packages are installed on all images:

| Package | Contents |
|---|---|
| `gstreamer1.0-plugins-base` | Core elements: `v4l2src`, `videoconvert`, `capsfilter`, etc. |
| `gstreamer1.0-plugins-good` | `vp8enc`, `webmmux`, `rtpvp8pay`, and other good-quality plugins |
| `gstreamer1.0-plugins-bad` | Extended elements including `h264parse` (Vulkan sink is disabled — no windowing system) |
| `gstreamer1.0-plugins-ugly` | `x264enc` (H.264 software encoder) |
| `gstreamer1.0-libav` | FFmpeg-backed codec elements (`avenc_h264`, etc.) |

On Jetson targets, `gstreamer1.0-plugins-nvvideo4linux2` is also installed, providing the `nvv4l2h264enc` hardware H.264 encoder.

### GStreamer invocation

The agent invokes `gst-launch` with the `-q` (quiet) flag to suppress status messages such as `"Setting pipeline to PLAYING"` from being written to stdout. Without this flag, those messages corrupt the binary H.264 or VP8 stream read from stdout.

### Encoder selection

The agent probes available GStreamer elements at startup and selects an encoder according to the following priority:

1. **H.264 with `h264parse`** — when `h264parse` (from `gst-plugins-bad`) is available, the agent selects the first available H.264 encoder in priority order: `nvv4l2h264enc`, `v4l2h264enc`, `omxh264enc`, `avenc_h264`, `x264enc`, `openh264enc`, `vaapih264enc`, `nvh264enc`, `msdkh264enc`. The encoder output is normalized to Annex B byte-stream (see below).
2. **VP8** — when `h264parse` is absent but `vp8enc` and `webmmux` are available. VP8 in a WebM container requires no stream-format negotiation and is always decodable by the client.
3. **H.264 without normalization** — last resort when neither `h264parse` nor VP8 is available. Hardware encoders such as `nvv4l2h264enc` and `v4l2h264enc` emit byte-stream natively; `x264enc` may emit AVC in this case.

### Available encoders

| Encoder | GStreamer element | Hardware |
|---|---|---|
| H.264 (NVIDIA V4L2 hardware) | `nvv4l2h264enc` | Jetson only |
| H.264 (V4L2 M2M hardware) | `v4l2h264enc` | V4L2 M2M devices |
| H.264 (software, libx264) | `x264enc` | All targets |
| H.264 (software, FFmpeg) | `avenc_h264` | All targets |
| H.264 (software, OpenH264) | `openh264enc` | All targets |
| VP8 | `vp8enc` | All targets |

### H.264 colour format and profile handling

All H.264 encoder pipelines insert a colour-format caps filter before the encoder element to prevent encoders such as `x264enc` from selecting H.264 High 4:4:4 Predictive (profile 244) when the upstream colour format is 4:4:4. Profile 244 is rejected by VideoToolbox and most hardware decoders.

`nvv4l2h264enc` uses NV12 as its preferred input format; all other H.264 encoders use I420.

Explicit profile caps are added only where needed:

| Encoder | Pipeline segment |
|---|---|
| `nvv4l2h264enc` | `videoconvert ! video/x-raw,format=NV12 ! nvv4l2h264enc` |
| `v4l2h264enc` | `videoconvert ! video/x-raw,format=I420 ! v4l2h264enc ! video/x-h264,profile=baseline` |
| `x264enc` | `videoconvert ! video/x-raw,format=I420 ! x264enc tune=zerolatency ! video/x-h264,profile=high` |
| `openh264enc` | `videoconvert ! video/x-raw,format=I420 ! openh264enc` |
| `avenc_h264` | `videoconvert ! video/x-raw,format=I420 ! avenc_h264` |
| all others | `videoconvert ! video/x-raw,format=I420 ! <encoder>` |

### H.264 byte-stream normalization

When `h264parse` is available, every H.264 encoder pipeline is suffixed with:

```
! h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream,alignment=au
```

This normalizes the output to Annex B byte-stream with in-band, per-keyframe SPS/PPS. Without it, encoders such as `x264enc` default to `stream-format=avc` when piped to `fdsink`; AVC carries SPS/PPS out-of-band in the caps `codec_data`, which is discarded when the elementary stream is piped raw over gRPC, making the stream undecodable by the client. Annex B with repeated SPS/PPS also allows the client to sync mid-stream.

When `h264parse` is absent, hardware encoders such as `nvv4l2h264enc` and `v4l2h264enc` output byte-stream natively; `x264enc` may output AVC in that case.

`v4l2h264enc` is capped to `baseline` because some V4L2 hardware encoders report H.264 support but fail to deliver frames; if no frames are received before the first DQBUF error, the agent falls back to the GStreamer software encoder path automatically.

### Client playback pipeline

The client receives the elementary stream over gRPC and pipes it to a local `gst-launch` process:

**H.264:**
```
fdsrc fd=0 ! typefind ! h264parse ! avdec_h264 ! videoconvert ! queue max-size-buffers=1 leaky=downstream ! autovideosink sync=false
```

`typefind` is required between `fdsrc` and `h264parse` because `fdsrc` emits untyped buffers (no caps). A bare `video/x-h264` capsfilter cannot bridge that gap — it must fixate caps onto the untyped buffers, but `video/x-h264` alone is unfixed (width/height/framerate are template ranges), causing the pipeline to fail with "Output caps are unfixed". `typefind` inspects the actual bytes, detects the H.264 start codes, and sets content-derived caps; `h264parse` then auto-detects whether the stream is Annex B byte-stream or length-prefixed AVC.

**VP8:**
```
fdsrc fd=0 ! matroskademux ! vp8dec ! queue max-size-buffers=1 leaky=downstream ! autovideosink sync=false
```

VP8 is sent in a WebM container (`webmmux streamable=true`), which `matroskademux` can parse from a pipe.

## App Configuration

```json
{
  "appId": "com.example.camera",
  "version": "1.0.0",
  "entitlements": [
    { "type": "camera" }
  ]
}
```

To restrict the app to one camera device:

```json
{ "type": "camera", "allowlist": ["/dev/video0"] }
```
