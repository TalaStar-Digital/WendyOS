package services

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"go.uber.org/zap"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/wendylabsinc/wendy/go/internal/agent/board"
	"github.com/wendylabsinc/wendy/go/internal/agent/camera"
	agentpb "github.com/wendylabsinc/wendy/go/proto/gen/agentpb"
)

// V4L2 ioctl constants for Linux kernel video capture interface.
const (
	v4l2BufTypeVideoCapture = 1
	v4l2MemoryMmap          = 1
	v4l2PixFmtH264          = 0x34363248 // 'H264' little-endian FourCC
	v4l2FieldNone           = 1

	vidiocSFmt      = 0xC0D05605
	vidiocReqbufs   = 0xC0145608
	vidiocQuerybuf  = 0xC0585609
	vidiocQbuf      = 0xC058560F
	vidiocDqbuf     = 0xC0585611
	vidiocStreamon  = 0x40045612
	vidiocStreamoff = 0x40045613
)

// v4l2Format matches struct v4l2_format (208 bytes) for V4L2_BUF_TYPE_VIDEO_CAPTURE.
type v4l2Format struct {
	Type         uint32
	Width        uint32
	Height       uint32
	PixelFormat  uint32
	Field        uint32
	BytesPerLine uint32
	SizeImage    uint32
	Colorspace   uint32
	Priv         uint32
	Flags        uint32
	Enc          uint32
	Quantization uint32
	XferFunc     uint32
	_            [156]byte
}

// v4l2ReqBuffers matches struct v4l2_requestbuffers (20 bytes).
type v4l2ReqBuffers struct {
	Count        uint32
	Type         uint32
	Memory       uint32
	Capabilities uint32
	Flags        uint32
}

// v4l2Buf is a fixed-size byte array matching struct v4l2_buffer (88 bytes on 64-bit Linux).
// Accessor methods read/write fields at their known offsets to avoid C-struct alignment surprises.
type v4l2Buf [88]byte

func (b *v4l2Buf) index() uint32      { return *(*uint32)(unsafe.Pointer(&b[0])) }
func (b *v4l2Buf) setIndex(i uint32)  { *(*uint32)(unsafe.Pointer(&b[0])) = i }
func (b *v4l2Buf) setType(t uint32)   { *(*uint32)(unsafe.Pointer(&b[4])) = t }
func (b *v4l2Buf) bytesUsed() uint32  { return *(*uint32)(unsafe.Pointer(&b[8])) }
func (b *v4l2Buf) setMemory(m uint32) { *(*uint32)(unsafe.Pointer(&b[60])) = m }
func (b *v4l2Buf) offset() uint32     { return *(*uint32)(unsafe.Pointer(&b[64])) }

// nativeH264NotSupported is returned when the V4L2 device does not expose H.264 output.
type nativeH264NotSupported struct{ msg string }

func (e nativeH264NotSupported) Error() string { return e.msg }

// VideoService implements agentpb.WendyVideoServiceServer.
type VideoService struct {
	agentpb.UnimplementedWendyVideoServiceServer
	logger             *zap.Logger
	globDevices        func() ([]string, error)
	readDeviceName     func(base string) (string, error)
	classifyTransport  func(base string) (camera.Transport, string)
	enumerateLibcamera func(ctx context.Context) (map[string]string, error)
	isJetson           func() bool
}

// NewVideoService creates a new VideoService.
func NewVideoService(logger *zap.Logger) *VideoService {
	return &VideoService{
		logger: logger,
		globDevices: func() ([]string, error) {
			return filepath.Glob("/dev/video*")
		},
		readDeviceName: func(base string) (string, error) {
			b, err := os.ReadFile(fmt.Sprintf("/sys/class/video4linux/%s/name", base))
			return strings.TrimSpace(string(b)), err
		},
		classifyTransport:  camera.Classify,
		enumerateLibcamera: camera.EnumerateLibcamera,
		isJetson:           func() bool { return board.Detect().IsJetson() },
	}
}

// listV4L2Devices enumerates /dev/video* and reads human-readable names from sysfs.
// It also classifies each device's transport (CSI vs USB vs unknown) and, when
// libcamera enumeration unambiguously identifies the CSI camera, attaches the
// libcamera id so the agent can later pass it as `libcamerasrc camera-name=...`.
func (s *VideoService) listV4L2Devices(ctx context.Context) ([]*agentpb.VideoDevice, error) {
	paths, err := s.globDevices()
	if err != nil {
		return nil, err
	}
	libcameraIDs, libErr := s.enumerateLibcamera(ctx)
	if libErr != nil {
		// Enumeration errors are non-fatal — we just lose the libcamera id enrichment.
		s.logger.Debug("libcamera enumeration failed", zap.Error(libErr))
	}
	var (
		devices       []*agentpb.VideoDevice
		csiDeviceIdxs []int
	)
	for _, path := range paths {
		base := filepath.Base(path)
		numStr := strings.TrimPrefix(base, "video")
		id, err := strconv.ParseUint(numStr, 10, 32)
		if err != nil {
			continue
		}
		name, err := s.readDeviceName(base)
		if err != nil {
			name = base
		}
		transport, driver := s.classifyTransport(base)
		dev := &agentpb.VideoDevice{
			Id:        uint32(id),
			Name:      name,
			Path:      path,
			Transport: transportToProto(transport),
			Driver:    driver,
		}
		if transport == camera.TransportCSI {
			csiDeviceIdxs = append(csiDeviceIdxs, len(devices))
		}
		devices = append(devices, dev)
	}
	// Only assign a libcamera_id in the unambiguous single-CSI / single-libcamera
	// case. With multiple cameras the /dev/videoN ↔ libcamera-name mapping is
	// fragile across libcamera versions, so we leave the field empty and let
	// libcamerasrc auto-select at capture time.
	if len(csiDeviceIdxs) == 1 && len(libcameraIDs) == 1 {
		for id := range libcameraIDs {
			devices[csiDeviceIdxs[0]].LibcameraId = id
		}
	}
	return devices, nil
}

// ListVideoDevices enumerates V4L2 video capture devices.
func (s *VideoService) ListVideoDevices(ctx context.Context, _ *agentpb.ListVideoDevicesRequest) (*agentpb.ListVideoDevicesResponse, error) {
	devices, err := s.listV4L2Devices(ctx)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to enumerate video devices: %v", err)
	}
	return &agentpb.ListVideoDevicesResponse{Devices: devices}, nil
}

// transportToProto converts the local Transport enum into its proto equivalent.
func transportToProto(t camera.Transport) agentpb.VideoTransport {
	switch t {
	case camera.TransportUSB:
		return agentpb.VideoTransport_VIDEO_TRANSPORT_USB
	case camera.TransportCSI:
		return agentpb.VideoTransport_VIDEO_TRANSPORT_CSI
	default:
		return agentpb.VideoTransport_VIDEO_TRANSPORT_UNKNOWN
	}
}

// StreamVideo streams H.264 frames from a V4L2 camera.
// For USB cameras it tries native H.264 capture via V4L2 mmap first and falls
// back to GStreamer if the device does not expose H.264 output. For CSI
// (ribbon) cameras it skips the native path — CSI sensors emit raw Bayer/RGB,
// not encoded H.264 — and goes straight to GStreamer (libcamerasrc when
// available, v4l2src otherwise).
func (s *VideoService) StreamVideo(req *agentpb.StreamVideoRequest, stream grpc.ServerStreamingServer[agentpb.VideoFrame]) error {
	ctx := stream.Context()
	path := fmt.Sprintf("/dev/video%d", req.GetDeviceId())

	if _, err := os.Stat(path); err != nil {
		available, listErr := s.globDevices()
		switch {
		case listErr != nil:
			return status.Errorf(codes.NotFound,
				"video device %s not found (and listing /dev/video* failed: %v); run 'wendy device camera list' to see available cameras",
				path, listErr)
		case len(available) == 0:
			return status.Errorf(codes.NotFound,
				"video device %s not found and no /dev/video* nodes exist on the agent host; for CSI ribbon cameras the sensor driver may be missing or its device-tree node may be disabled — check `dmesg | grep -iE 'imx|ov|tegra-capture'` and that the sensor module is installed under /lib/modules",
				path)
		default:
			return status.Errorf(codes.NotFound,
				"video device %s not found; available: %s — pass --id <N> matching one of those, or run 'wendy device camera list'",
				path, strings.Join(available, ", "))
		}
	}

	transport, _ := s.classifyTransport(filepath.Base(path))
	libcameraID := s.lookupLibcameraID(ctx, transport)

	if transport == camera.TransportCSI {
		s.logger.Info("CSI camera detected, using GStreamer", zap.String("device", path))
		return s.streamGStreamer(ctx, stream, path, req, transport, libcameraID)
	}

	err := s.streamV4L2Native(ctx, stream, path, req)
	if _, ok := err.(nativeH264NotSupported); ok {
		s.logger.Info("native H.264 not supported, falling back to GStreamer", zap.String("device", path))
		return s.streamGStreamer(ctx, stream, path, req, transport, libcameraID)
	}
	return err
}

// lookupLibcameraID enumerates libcamera once and returns the camera-name to
// use, but only when the mapping is unambiguous (exactly one libcamera entry
// for a CSI device). Returns "" otherwise; callers should let libcamerasrc
// auto-select in that case.
func (s *VideoService) lookupLibcameraID(ctx context.Context, transport camera.Transport) string {
	if transport != camera.TransportCSI {
		return ""
	}
	ids, err := s.enumerateLibcamera(ctx)
	if err != nil || len(ids) != 1 {
		return ""
	}
	for id := range ids {
		return id
	}
	return ""
}

// streamV4L2Native opens the V4L2 device, configures H.264 output via VIDIOC_S_FMT,
// allocates mmap buffers, and streams frames until ctx is cancelled or an error occurs.
// Returns nativeH264NotSupported if the device rejects the H.264 pixel format.
func (s *VideoService) streamV4L2Native(ctx context.Context, stream grpc.ServerStreamingServer[agentpb.VideoFrame], path string, req *agentpb.StreamVideoRequest) error {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return status.Errorf(codes.Internal, "open %s: %v", path, err)
	}
	defer unix.Close(fd) //nolint:errcheck

	// Configure H.264 output format.
	var vfmt v4l2Format
	vfmt.Type = v4l2BufTypeVideoCapture
	if req.GetWidth() > 0 {
		vfmt.Width = req.GetWidth()
	}
	if req.GetHeight() > 0 {
		vfmt.Height = req.GetHeight()
	}
	vfmt.PixelFormat = v4l2PixFmtH264
	vfmt.Field = v4l2FieldNone

	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocSFmt, uintptr(unsafe.Pointer(&vfmt))); errno != 0 {
		if errno == unix.EINVAL {
			return nativeH264NotSupported{msg: fmt.Sprintf("VIDIOC_S_FMT H264 rejected: %v", errno)}
		}
		return status.Errorf(codes.Internal, "VIDIOC_S_FMT failed for %s: %v", path, errno)
	}
	if vfmt.PixelFormat != v4l2PixFmtH264 {
		return nativeH264NotSupported{msg: "device switched pixel format away from H264"}
	}

	// Two buffers: one dequeued/in-flight, one queued for the camera to fill.
	// More buffers increase kernel-side lag when the gRPC send lags the camera.
	const numBuffers = 2
	var req4 v4l2ReqBuffers
	req4.Count = numBuffers
	req4.Type = v4l2BufTypeVideoCapture
	req4.Memory = v4l2MemoryMmap

	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocReqbufs, uintptr(unsafe.Pointer(&req4))); errno != 0 {
		return status.Errorf(codes.Internal, "VIDIOC_REQBUFS: %v", errno)
	}
	if req4.Count < 2 {
		return status.Errorf(codes.Internal, "insufficient buffer memory on device")
	}

	// Map and queue each buffer.
	type mappedBuf struct {
		data []byte
	}
	mapped := make([]mappedBuf, req4.Count)

	for i := uint32(0); i < req4.Count; i++ {
		var qbuf v4l2Buf
		qbuf.setIndex(i)
		qbuf.setType(v4l2BufTypeVideoCapture)
		qbuf.setMemory(v4l2MemoryMmap)

		if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocQuerybuf, uintptr(unsafe.Pointer(&qbuf))); errno != 0 {
			return status.Errorf(codes.Internal, "VIDIOC_QUERYBUF[%d]: %v", i, errno)
		}

		length := uint32(*(*uint32)(unsafe.Pointer(&qbuf[72]))) // length at offset 72 in v4l2_buffer
		data, err := unix.Mmap(fd, int64(qbuf.offset()), int(length), unix.PROT_READ|unix.PROT_WRITE, unix.MAP_SHARED)
		if err != nil {
			return status.Errorf(codes.Internal, "mmap buffer %d: %v", i, err)
		}
		mapped[i].data = data

		if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocQbuf, uintptr(unsafe.Pointer(&qbuf))); errno != 0 {
			return status.Errorf(codes.Internal, "VIDIOC_QBUF[%d]: %v", i, errno)
		}
	}
	defer func() {
		for _, m := range mapped {
			unix.Munmap(m.data) //nolint:errcheck
		}
	}()

	// Start streaming.
	bufType := uint32(v4l2BufTypeVideoCapture)
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocStreamon, uintptr(unsafe.Pointer(&bufType))); errno != 0 {
		return status.Errorf(codes.Internal, "VIDIOC_STREAMON: %v", errno)
	}
	defer func() {
		unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocStreamoff, uintptr(unsafe.Pointer(&bufType))) //nolint:errcheck
	}()

	var framesSent int
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		var dqbuf v4l2Buf
		dqbuf.setType(v4l2BufTypeVideoCapture)
		dqbuf.setMemory(v4l2MemoryMmap)

		if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocDqbuf, uintptr(unsafe.Pointer(&dqbuf))); errno != 0 {
			if errno == unix.EINTR || errno == unix.EAGAIN {
				continue
			}
			// Device accepted H264 format but failed before delivering any frame —
			// fall back to the GStreamer software encoder path.
			if framesSent == 0 {
				return nativeH264NotSupported{msg: fmt.Sprintf("VIDIOC_DQBUF failed before first frame: %v", errno)}
			}
			return status.Errorf(codes.Internal, "VIDIOC_DQBUF: %v", errno)
		}

		idx := dqbuf.index()
		n := dqbuf.bytesUsed()
		if n == 0 {
			// Empty buffer — requeue and skip.
			var qbuf v4l2Buf
			qbuf.setIndex(idx)
			qbuf.setType(v4l2BufTypeVideoCapture)
			qbuf.setMemory(v4l2MemoryMmap)
			if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocQbuf, uintptr(unsafe.Pointer(&qbuf))); errno != 0 {
				return status.Errorf(codes.Internal, "VIDIOC_QBUF: %v", errno)
			}
			continue
		}
		frameData := make([]byte, n)
		copy(frameData, mapped[idx].data[:n])

		if err := stream.Send(&agentpb.VideoFrame{
			Data:        frameData,
			TimestampNs: uint64(time.Now().UnixNano()),
		}); err != nil {
			return err
		}
		framesSent++

		// Re-queue the buffer.
		var qbuf v4l2Buf
		qbuf.setIndex(idx)
		qbuf.setType(v4l2BufTypeVideoCapture)
		qbuf.setMemory(v4l2MemoryMmap)
		if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), vidiocQbuf, uintptr(unsafe.Pointer(&qbuf))); errno != 0 {
			return status.Errorf(codes.Internal, "VIDIOC_QBUF requeue[%d]: %v", idx, errno)
		}
	}
}

// gstFallbackDirs is the list of directories searched for GStreamer binaries
// when they are not on PATH. wendy-agent runs as a systemd service whose
// inherited PATH may omit the standard system bin directories (observed on
// wendyOS, where a CUDA setup file leaves PATH=/usr/local/cuda-XX/bin:$PATH
// — the literal "$PATH" not being expanded). Declared as a var so tests can
// override it.
var gstFallbackDirs = []string{"/usr/bin", "/usr/local/bin", "/usr/sbin"}

// resolveGSTBinary looks up a GStreamer binary on PATH first, then falls back
// to known system locations.
func resolveGSTBinary(name string) (string, error) {
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	for _, dir := range gstFallbackDirs {
		candidate := filepath.Join(dir, name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s not found; install GStreamer on the device", name)
}

// hostIsJetson reports whether the agent host is a Jetson, tolerating a nil
// injection (struct-literal-constructed services in tests treat it as false).
func (s *VideoService) hostIsJetson() bool {
	if s.isJetson == nil {
		return false
	}
	return s.isJetson()
}

// streamGStreamer spawns gst-launch-1.0 on the device to encode via the best available
// encoder and pipes the resulting stream back as VideoFrame chunks.
func (s *VideoService) streamGStreamer(ctx context.Context, stream grpc.ServerStreamingServer[agentpb.VideoFrame], path string, req *agentpb.StreamVideoRequest, transport camera.Transport, libcameraID string) (runErr error) {
	gstPath, err := resolveGSTBinary("gst-launch-1.0")
	if err != nil {
		return status.Errorf(codes.FailedPrecondition, "%v", err)
	}
	inspectPath, err := resolveGSTBinary("gst-inspect-1.0")
	if err != nil {
		return status.Errorf(codes.FailedPrecondition, "%v", err)
	}

	available, listErr := listGSTElements(inspectPath)
	if listErr != nil {
		// findGStreamerEncoder handles a nil/empty set by attempting x264enc.
		s.logger.Debug("gst-inspect listing failed", zap.Error(listErr))
		available = nil
	}

	enc, err := findGStreamerEncoderFromSet(available)
	if err != nil {
		return status.Errorf(codes.FailedPrecondition, "%v", err)
	}
	s.logger.Info("GStreamer encoder selected", zap.String("encoder", enc.element), zap.String("codec", enc.codec.String()))

	var args []string
	if useArgusSource(transport, s.hostIsJetson(), available) {
		// Argus indexes sensors by sensor-id; /dev/videoN maps to sensor-id N
		// for the common single-CSI-camera case.
		sensorID := int(req.GetDeviceId())
		s.logger.Info("CSI camera on Jetson — capturing via nvarguscamerasrc (Argus)",
			zap.Int("sensor_id", sensorID), zap.String("encoder", enc.element))
		args = buildArgusGStreamerArgs(gstPath, req, sensorID, enc.element, enc.hasH264Parse, available)
	} else {
		args = buildGStreamerArgs(gstPath, path, req, enc.element, enc.hasH264Parse, transport, libcameraID, available)
	}
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return status.Errorf(codes.Internal, "failed to create GStreamer pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		return status.Errorf(codes.Internal, "failed to start GStreamer: %v", err)
	}

	defer func() {
		cmd.Process.Kill()          //nolint:errcheck
		io.Copy(io.Discard, stdout) // drain so Wait's internal goroutine can exit
		waitErr := cmd.Wait()
		if runErr == nil {
			msg := strings.TrimSpace(stderrBuf.String())
			if msg != "" {
				runErr = status.Errorf(codes.Internal, "gstreamer exited with error: %s", msg)
			} else if waitErr != nil {
				runErr = status.Errorf(codes.Internal, "gstreamer exited with error: %v", waitErr)
			}
		}
	}()

	const chunkSize = 256 * 1024
	buf := make([]byte, chunkSize)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		n, readErr := stdout.Read(buf)
		if n > 0 {
			frameData := make([]byte, n)
			copy(frameData, buf[:n])
			if sendErr := stream.Send(&agentpb.VideoFrame{
				Data:        frameData,
				TimestampNs: uint64(time.Now().UnixNano()),
				Codec:       enc.codec,
			}); sendErr != nil {
				return sendErr
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				return nil // normal termination; defer surfaces stderr/exit errors
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return status.Errorf(codes.Internal, "failed to read GStreamer output: %v", readErr)
		}
	}
}

// gstEncoderResult describes a found GStreamer encoder and the codec it produces.
type gstEncoderResult struct {
	element      string
	codec        agentpb.VideoCodec
	hasH264Parse bool // whether h264parse is available on this device
}

// findGStreamerEncoder probes available encoders by listing all elements once via
// gst-inspect-1.0 (no args) and building a lookup set. Per-element subprocess calls
// are unreliable on some builds; the list command is authoritative.
func findGStreamerEncoder(inspectPath string) (gstEncoderResult, error) {
	available, err := listGSTElements(inspectPath)
	if err != nil {
		// If listing fails, attempt x264enc and let gst-launch fail with a clear message.
		return gstEncoderResult{element: "x264enc", codec: agentpb.VideoCodec_VIDEO_CODEC_H264}, nil
	}
	return findGStreamerEncoderFromSet(available)
}

// findGStreamerEncoderFromSet performs encoder selection against a precomputed
// element availability map. When available is nil (e.g. gst-inspect listing
// failed), it falls back to attempting x264enc.
func findGStreamerEncoderFromSet(available map[string]bool) (gstEncoderResult, error) {
	if available == nil {
		return gstEncoderResult{element: "x264enc", codec: agentpb.VideoCodec_VIDEO_CODEC_H264}, nil
	}

	hasElem := func(name string) bool { return available[name] }
	h264Parse := hasElem("h264parse")

	h264Encoders := []string{
		"nvv4l2h264enc", // NVIDIA V4L2 hardware (Jetson L4T, gstreamer1.0-plugins-nvvideo4linux2)
		"v4l2h264enc",   // V4L2 M2M hardware (gst-plugins-good)
		"omxh264enc",    // OpenMAX hardware (Broadcom, Qualcomm)
		"avenc_h264",    // libavcodec bridge (gst-libav)
		"x264enc",       // software (gst-plugins-ugly)
		"openh264enc",   // software (gst-plugins-bad)
		"vaapih264enc",  // Intel VA-API
		"nvh264enc",     // NVIDIA NVENC (desktop)
		"msdkh264enc",   // Intel Media SDK
	}

	// H.264 is preferred when h264parse is available to normalize output to Annex B
	// byte-stream. Without h264parse, encoders like x264enc emit stream-format=avc
	// which discards SPS/PPS when piped raw over gRPC, making the stream undecodable.
	if h264Parse {
		for _, enc := range h264Encoders {
			if hasElem(enc) {
				return gstEncoderResult{element: enc, codec: agentpb.VideoCodec_VIDEO_CODEC_H264, hasH264Parse: true}, nil
			}
		}
		for name := range available {
			lower := strings.ToLower(name)
			if strings.Contains(lower, "h264") && strings.Contains(lower, "enc") {
				return gstEncoderResult{element: name, codec: agentpb.VideoCodec_VIDEO_CODEC_H264, hasH264Parse: true}, nil
			}
		}
	}

	// VP8 preferred over raw H.264 when h264parse is absent: vp8enc+webmmux (both
	// in gst-plugins-good) produce a self-describing WebM container that requires no
	// stream-format negotiation and is always decodable by the client.
	if hasElem("vp8enc") && hasElem("webmmux") {
		return gstEncoderResult{element: "vp8enc", codec: agentpb.VideoCodec_VIDEO_CODEC_VP8}, nil
	}

	// Last resort: attempt H.264 without normalization. Hardware encoders such as
	// nvv4l2h264enc and v4l2h264enc typically emit byte-stream natively; x264enc may
	// produce AVC which the client's h264parse may or may not be able to decode.
	for _, enc := range h264Encoders {
		if hasElem(enc) {
			return gstEncoderResult{element: enc, codec: agentpb.VideoCodec_VIDEO_CODEC_H264, hasH264Parse: false}, nil
		}
	}
	for name := range available {
		lower := strings.ToLower(name)
		if strings.Contains(lower, "h264") && strings.Contains(lower, "enc") {
			return gstEncoderResult{element: name, codec: agentpb.VideoCodec_VIDEO_CODEC_H264}, nil
		}
	}

	return gstEncoderResult{}, fmt.Errorf(
		"no supported GStreamer encoder found (checked %d elements); install gst-plugins-good (vp8enc+webmmux) or gst-plugins-bad (h264parse)+gst-plugins-ugly (x264enc)",
		len(available),
	)
}

// listGSTElements runs gst-inspect-1.0 once and returns a set of all available element names.
// Each output line has the form "plugin:  element: description".
func listGSTElements(inspectPath string) (map[string]bool, error) {
	out, err := exec.Command(inspectPath).Output()
	if err != nil {
		return nil, fmt.Errorf("gst-inspect-1.0: %w", err)
	}
	elements := make(map[string]bool)
	for _, line := range strings.Split(string(out), "\n") {
		// Split on ": " to get plugin and element name (first two fields).
		parts := strings.SplitN(line, ":", 3)
		if len(parts) < 2 {
			continue
		}
		name := strings.TrimSpace(parts[1])
		if name != "" && !strings.ContainsAny(name, " \t") {
			elements[name] = true
		}
	}
	return elements, nil
}

// Argus sensor-mode defaults, applied when the request leaves a dimension at 0.
// nvarguscamerasrc needs explicit width/height to pick a sensor mode; without
// them it defaults to the sensor's largest mode (e.g. 4032x3040), which is
// needlessly heavy for a live view.
const (
	argusDefaultWidth     = 1920
	argusDefaultHeight    = 1080
	argusDefaultFramerate = 30
)

// buildArgusGStreamerArgs builds a gst-launch-1.0 pipeline that captures from a
// Jetson CSI sensor via nvarguscamerasrc (ISP-processed NV12 in NVMM memory) and
// encodes to H.264. The nvv4l2h264enc hardware encoder consumes NVMM NV12
// directly (zero-copy); any other encoder needs frames copied to system memory
// first via nvvidconv. sensorID is the Argus sensor index (derived from the
// /dev/videoN suffix by the caller; correct for the common single-CSI-camera
// case).
func buildArgusGStreamerArgs(gstPath string, req *agentpb.StreamVideoRequest, sensorID int, encoder string, hasH264Parse bool, available map[string]bool) []string {
	width := req.GetWidth()
	if width == 0 {
		width = argusDefaultWidth
	}
	height := req.GetHeight()
	if height == 0 {
		height = argusDefaultHeight
	}
	framerate := req.GetFramerate()
	if framerate == 0 {
		framerate = argusDefaultFramerate
	}
	nvmmCaps := fmt.Sprintf("video/x-raw(memory:NVMM),width=%d,height=%d,framerate=%d/1,format=NV12", width, height, framerate)

	var tail string
	if encoder == "nvv4l2h264enc" {
		// HW encoder accepts NVMM NV12 directly — no copy to system memory.
		tail = "nvv4l2h264enc"
		if hasH264Parse {
			tail += h264ByteStream
		}
	} else {
		// Any other encoder needs frames in system memory; nvvidconv does the
		// NVMM->CPU copy, then the shared encoderSegment handles the rest.
		tail = "nvvidconv ! video/x-raw,format=NV12 ! " + encoderSegment(encoder, hasH264Parse)
	}

	pipeline := fmt.Sprintf("nvarguscamerasrc sensor-id=%d ! %s ! %s ! fdsink fd=1", sensorID, nvmmCaps, tail)
	// -q matches buildGStreamerArgs: suppress gst-launch status text so it does
	// not corrupt the binary H.264 stream on stdout.
	return append([]string{gstPath, "-q"}, strings.Fields(pipeline)...)
}

// buildGStreamerArgs constructs the gst-launch-1.0 argument list. The capture
// source is selected by transport:
//
//   - CSI with libcamerasrc available  → "libcamerasrc [camera-name=<id>]"
//   - CSI without libcamerasrc        → "v4l2src device=<path>" (degraded; may
//     produce unusable output if the sensor needs ISP, but the pipeline starts)
//   - USB / Unknown                    → "v4l2src device=<path>" (unchanged)
//
// `available` may be nil; treat nil as "libcamerasrc not known to be present"
// and degrade to v4l2src for CSI in that case.
func buildGStreamerArgs(gstPath, devicePath string, req *agentpb.StreamVideoRequest, encoder string, hasH264Parse bool, transport camera.Transport, libcameraID string, available map[string]bool) []string {
	src := buildSourceElement(devicePath, transport, libcameraID, available)

	var capsParts []string
	if req.GetWidth() > 0 {
		capsParts = append(capsParts, fmt.Sprintf("width=%d", req.GetWidth()))
	}
	if req.GetHeight() > 0 {
		capsParts = append(capsParts, fmt.Sprintf("height=%d", req.GetHeight()))
	}
	if req.GetFramerate() > 0 {
		capsParts = append(capsParts, fmt.Sprintf("framerate=%d/1", req.GetFramerate()))
	}

	var pipeline string
	if len(capsParts) > 0 {
		caps := "video/x-raw," + strings.Join(capsParts, ",")
		pipeline = fmt.Sprintf("%s ! %s ! %s ! fdsink fd=1", src, caps, encoderSegment(encoder, hasH264Parse))
	} else {
		pipeline = fmt.Sprintf("%s ! %s ! fdsink fd=1", src, encoderSegment(encoder, hasH264Parse))
	}
	// -q suppresses gst-launch's status messages (e.g. "Setting pipeline to PLAYING")
	// from being written to stdout and corrupting the binary H264 stream.
	return append([]string{gstPath, "-q"}, strings.Fields(pipeline)...)
}

// useArgusSource reports whether the NVIDIA Argus capture path should be used:
// a CSI sensor, on a Jetson host, with the nvarguscamerasrc element installed.
// On Jetson L4T, libcamera has no Tegra pipeline handler (cam --list is empty)
// and plain v4l2src cannot drive the raw-Bayer VI pipeline, so nvarguscamerasrc
// (sensor -> ISP -> NVMM NV12) is the only working GStreamer source.
func useArgusSource(transport camera.Transport, isJetson bool, available map[string]bool) bool {
	return transport == camera.TransportCSI && isJetson && available != nil && available["nvarguscamerasrc"]
}

// buildSourceElement chooses the capture source element for the GStreamer
// pipeline. See buildGStreamerArgs for the selection rules.
func buildSourceElement(devicePath string, transport camera.Transport, libcameraID string, available map[string]bool) string {
	if transport == camera.TransportCSI && available != nil && available["libcamerasrc"] {
		if libcameraID != "" {
			return fmt.Sprintf("libcamerasrc camera-name=%s", libcameraID)
		}
		return "libcamerasrc"
	}
	return fmt.Sprintf("v4l2src device=%s", devicePath)
}

// h264ByteStream normalizes any encoder's H.264 output to Annex B byte-stream
// with in-band, per-keyframe SPS/PPS (config-interval=-1).
//
// Without it, encoders such as x264enc default to stream-format=avc when piped
// to fdsink (its src caps list "avc" before "byte-stream", and fdsink imposes no
// constraint). AVC carries SPS/PPS out-of-band in the caps codec_data, which is
// discarded when the elementary stream is piped raw over gRPC. The client's
// `fdsrc ! typefind ! h264parse` pipeline then sees length-prefixed NALs with no
// start codes and fails with "Could not determine type of stream". Annex B with
// repeated SPS/PPS also lets the client sync mid-stream.
const h264ByteStream = " ! h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream,alignment=au"

// encoderSegment returns the GStreamer pipeline segment for the given encoder element.
// Most H.264 encoders force I420 (4:2:0) input to avoid 4:4:4 output paths that
// can make encoders such as x264enc select profile 244 (High 4:4:4 Predictive),
// which VideoToolbox and most hardware decoders reject. This input cap does not by
// itself enforce a specific H.264 output profile; explicit profile caps are added
// only where needed. When h264parse is available, every H.264 segment is suffixed
// with h264ByteStream to normalize to Annex B byte-stream. When h264parse is absent
// (gst-plugins-bad not installed), hardware encoders such as nvv4l2h264enc and
// v4l2h264enc output byte-stream natively; x264enc may output AVC in that case.
func encoderSegment(encoder string, hasH264Parse bool) string {
	if encoder == "vp8enc" {
		// webmmux streamable=true writes headers that matroskademux can parse from a pipe.
		return "videoconvert ! vp8enc deadline=1 ! webmmux streamable=true"
	}

	var enc string
	switch encoder {
	case "nvv4l2h264enc":
		// Jetson L4T hardware encoder; NV12 is its preferred input format.
		enc = "videoconvert ! video/x-raw,format=NV12 ! nvv4l2h264enc"
	case "v4l2h264enc":
		enc = "videoconvert ! video/x-raw,format=I420 ! v4l2h264enc ! video/x-h264,profile=baseline"
	case "x264enc":
		enc = "videoconvert ! video/x-raw,format=I420 ! x264enc tune=zerolatency ! video/x-h264,profile=high"
	case "openh264enc":
		enc = "videoconvert ! video/x-raw,format=I420 ! openh264enc"
	case "avenc_h264":
		enc = "videoconvert ! video/x-raw,format=I420 ! avenc_h264"
	default:
		// For other H.264-family encoders, force I420 to avoid 4:4:4 profile selection.
		enc = "videoconvert ! video/x-raw,format=I420 ! " + encoder
	}
	if hasH264Parse {
		return enc + h264ByteStream
	}
	return enc
}
