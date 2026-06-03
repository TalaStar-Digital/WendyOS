package services

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendy/go/internal/agent/camera"
	agentpb "github.com/wendylabsinc/wendy/go/proto/gen/agentpb"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// newTestVideoService creates a VideoService with injectable filesystem functions.
// classifyTransport defaults to "Unknown, empty driver" and enumerateLibcamera
// defaults to (nil, nil) so existing tests do not need to thread those through.
func newTestVideoService(glob func() ([]string, error), readName func(string) (string, error)) *VideoService {
	svc := NewVideoService(zap.NewNop())
	if glob != nil {
		svc.globDevices = glob
	}
	if readName != nil {
		svc.readDeviceName = readName
	}
	svc.classifyTransport = func(string) (camera.Transport, string) { return camera.TransportUnknown, "" }
	svc.enumerateLibcamera = func(context.Context) (map[string]string, error) { return nil, nil }
	return svc
}

func TestListV4L2Devices_TwoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0", "/dev/video1"}, nil },
		func(base string) (string, error) {
			names := map[string]string{"video0": "USB Camera", "video1": "Integrated Camera"}
			if name, ok := names[base]; ok {
				return name, nil
			}
			return base, nil
		},
	)

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
	if devices[0].GetId() != 0 || devices[0].GetName() != "USB Camera" || devices[0].GetPath() != "/dev/video0" {
		t.Errorf("device 0: got id=%d name=%q path=%q", devices[0].GetId(), devices[0].GetName(), devices[0].GetPath())
	}
	if devices[1].GetId() != 1 || devices[1].GetName() != "Integrated Camera" || devices[1].GetPath() != "/dev/video1" {
		t.Errorf("device 1: got id=%d name=%q path=%q", devices[1].GetId(), devices[1].GetName(), devices[1].GetPath())
	}
}

func TestListV4L2Devices_NoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, nil },
		nil,
	)

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 0 {
		t.Fatalf("expected 0 devices, got %d", len(devices))
	}
}

func TestListV4L2Devices_SysfsReadFailFallsBackToPath(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(base string) (string, error) { return "", fmt.Errorf("no sysfs") },
	)

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(devices))
	}
	if devices[0].GetName() != "video0" {
		t.Errorf("expected fallback name 'video0', got %q", devices[0].GetName())
	}
}

func TestListV4L2Devices_GlobError(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, fmt.Errorf("permission denied") },
		nil,
	)

	_, err := svc.listV4L2Devices(context.Background())
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestVideoService_ListVideoDevices(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(base string) (string, error) { return "Test Camera", nil },
	)

	resp, err := svc.ListVideoDevices(context.Background(), &agentpb.ListVideoDevicesRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(resp.GetDevices()) != 1 {
		t.Fatalf("expected 1 device, got %d", len(resp.GetDevices()))
	}
	d := resp.GetDevices()[0]
	if d.GetId() != 0 || d.GetName() != "Test Camera" || d.GetPath() != "/dev/video0" {
		t.Errorf("unexpected device: id=%d name=%q path=%q", d.GetId(), d.GetName(), d.GetPath())
	}
}

func TestVideoService_ListVideoDevices_GlobError(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return nil, fmt.Errorf("permission denied") },
		nil,
	)

	_, err := svc.ListVideoDevices(context.Background(), &agentpb.ListVideoDevicesRequest{})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected gRPC status error, got: %v", err)
	}
	if st.Code() != codes.Internal {
		t.Errorf("expected codes.Internal, got %v", st.Code())
	}
}

func TestBuildGStreamerArgs_NoDimensions(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "x264enc", true, camera.TransportUSB, "", nil)
	if len(args) == 0 || args[0] != "/usr/bin/gst-launch-1.0" {
		t.Errorf("expected first arg to be gst-launch-1.0 path, got %v", args)
	}
	if len(args) < 2 || args[1] != "-q" {
		t.Errorf("expected -q as second arg to suppress stdout noise, got %v", args)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "v4l2src") || !strings.Contains(joined, "x264enc") || !strings.Contains(joined, "fdsink") {
		t.Errorf("pipeline missing expected elements: %v", args)
	}
	if !strings.Contains(joined, "profile=high") {
		t.Errorf("x264enc pipeline must constrain profile=high for iOS compatibility: %v", args)
	}
	// The H.264 stream must be normalized to Annex B byte-stream with in-band
	// SPS/PPS; otherwise x264enc emits stream-format=avc and the client's
	// typefind cannot classify the raw piped stream.
	if !strings.Contains(joined, "h264parse config-interval=-1") {
		t.Errorf("server-side pipeline must repeat SPS/PPS via h264parse config-interval=-1: %v", args)
	}
	if !strings.Contains(joined, "video/x-h264,stream-format=byte-stream,alignment=au") {
		t.Errorf("server-side pipeline must force Annex B byte-stream output: %v", args)
	}
}

func TestBuildGStreamerArgs_WithoutH264Parse(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "x264enc", false, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "h264parse") {
		t.Errorf("pipeline must not use h264parse when unavailable: %v", args)
	}
	// No extra caps suffix: hardware encoders output byte-stream natively; x264enc
	// AVC output is an acceptable trade-off when h264parse is absent.
	if strings.Contains(joined, "stream-format") {
		t.Errorf("pipeline must not add stream-format caps when h264parse is unavailable: %v", args)
	}
}

func TestBuildGStreamerArgs_X264ProfileIsCapsFilter(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "x264enc", true, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "x264enc tune=zerolatency profile=high") {
		t.Fatalf("profile=high must be an output capsfilter, not an x264enc property: %v", args)
	}
	if !strings.Contains(joined, "x264enc tune=zerolatency ! video/x-h264,profile=high") {
		t.Fatalf("expected x264enc output capsfilter for high profile: %v", args)
	}
}

func TestBuildGStreamerArgs_WithDimensionsAndFramerate(t *testing.T) {
	req := &agentpb.StreamVideoRequest{Width: 1280, Height: 720, Framerate: 30}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "x264enc", true, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "width=1280") || !strings.Contains(joined, "height=720") || !strings.Contains(joined, "framerate=30/1") {
		t.Errorf("expected dimension caps in args: %v", args)
	}
}

func TestBuildGStreamerArgs_V4L2HardwareEncoder(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "v4l2h264enc", true, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "v4l2h264enc") || !strings.Contains(joined, "video/x-h264") {
		t.Errorf("expected v4l2h264enc pipeline segment: %v", args)
	}
}

func TestBuildGStreamerArgs_NVV4L2HardwareEncoder(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "nvv4l2h264enc", true, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "nvv4l2h264enc") {
		t.Errorf("expected nvv4l2h264enc in pipeline: %v", args)
	}
	if !strings.Contains(joined, "video/x-raw,format=NV12") {
		t.Errorf("expected NV12 capsfilter for nvv4l2h264enc: %v", args)
	}
}

func TestBuildGStreamerArgs_VP8Encoder(t *testing.T) {
	req := &agentpb.StreamVideoRequest{}
	args := buildGStreamerArgs("/usr/bin/gst-launch-1.0", "/dev/video0", req, "vp8enc", false, camera.TransportUSB, "", nil)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "vp8enc") || !strings.Contains(joined, "webmmux") {
		t.Errorf("expected vp8enc+webmmux pipeline segment: %v", args)
	}
	if strings.Contains(joined, "h264") {
		t.Errorf("VP8 pipeline should not mention h264: %v", args)
	}
}

func TestListGSTElements_ParsesElements(t *testing.T) {
	input := `
matroska:  matroskamux: Matroska muxer
matroska:  webmmux: WebM muxer
x264:  x264enc: H264 video encoder
vpx:  vp8enc: On2 VP8 Encoder
bad:  h264parse: H.264 parser
`
	// Inject a fake gst-inspect-1.0 that prints the above.
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+input+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	elements, err := listGSTElements(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{"matroskamux", "webmmux", "x264enc", "vp8enc", "h264parse"} {
		if !elements[want] {
			t.Errorf("expected %q in element list, got %v", want, elements)
		}
	}
}

func TestFindGStreamerEncoder_PrefersX264(t *testing.T) {
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"
	listing := "x264:  x264enc: H264 video encoder\nvpx:  vp8enc: VP8 encoder\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+listing+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err := findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.element != "x264enc" {
		t.Errorf("expected x264enc, got %q", result.element)
	}
	if result.codec != agentpb.VideoCodec_VIDEO_CODEC_H264 {
		t.Errorf("expected H264 codec, got %v", result.codec)
	}
}

func TestFindGStreamerEncoder_H264ParseDetection(t *testing.T) {
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"

	withH264Parse := "x264:  x264enc: H264 video encoder\nbad:  h264parse: H.264 parser\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+withH264Parse+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err := findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.hasH264Parse {
		t.Errorf("expected hasH264Parse=true when h264parse is listed, got false")
	}

	withoutH264Parse := "x264:  x264enc: H264 video encoder\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+withoutH264Parse+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err = findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.hasH264Parse {
		t.Errorf("expected hasH264Parse=false when h264parse is not listed, got true")
	}
}

func TestFindGStreamerEncoder_PrefersNVV4L2OverOtherH264Encoders(t *testing.T) {
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"
	listing := "x264:  x264enc: H264 video encoder\nvideo4linux2:  v4l2h264enc: V4L2 H264 encoder\nnvvideo4linux2:  nvv4l2h264enc: NVIDIA V4L2 H264 encoder\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+listing+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err := findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.element != "nvv4l2h264enc" {
		t.Errorf("expected nvv4l2h264enc, got %q", result.element)
	}
	if result.codec != agentpb.VideoCodec_VIDEO_CODEC_H264 {
		t.Errorf("expected H264 codec, got %v", result.codec)
	}
}

func TestFindGStreamerEncoder_PrefersVP8WhenH264ParseAbsent(t *testing.T) {
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"
	// x264enc present but h264parse absent; vp8enc+webmmux also present
	listing := "x264:  x264enc: H264 video encoder\nvpx:  vp8enc: VP8 encoder\nmatroska:  webmmux: WebM muxer\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+listing+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err := findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.element != "vp8enc" {
		t.Errorf("expected vp8enc when h264parse absent but webmmux available, got %q", result.element)
	}
	if result.codec != agentpb.VideoCodec_VIDEO_CODEC_VP8 {
		t.Errorf("expected VP8 codec, got %v", result.codec)
	}
}

func TestFindGStreamerEncoder_FallsBackToVP8WhenNoH264Encoder(t *testing.T) {
	tmpDir := t.TempDir()
	script := tmpDir + "/gst-inspect-1.0"
	listing := "vpx:  vp8enc: VP8 encoder\nmatroska:  webmmux: WebM muxer\n"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '"+listing+"'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	result, err := findGStreamerEncoder(script)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.element != "vp8enc" {
		t.Errorf("expected vp8enc fallback, got %q", result.element)
	}
	if result.codec != agentpb.VideoCodec_VIDEO_CODEC_VP8 {
		t.Errorf("expected VP8 codec, got %v", result.codec)
	}
}

func TestStreamGStreamer_MissingGStreamer(t *testing.T) {
	t.Setenv("PATH", "") // ensure gst-launch-1.0 is not found regardless of host installation
	// Also neutralize the systemd-PATH fallback search so this test is deterministic
	// on hosts where gst-launch-1.0 happens to live in /usr/bin etc.
	prev := gstFallbackDirs
	gstFallbackDirs = nil
	t.Cleanup(func() { gstFallbackDirs = prev })
	svc := NewVideoService(zap.NewNop())
	err := svc.streamGStreamer(context.Background(), nil, "/dev/video0", &agentpb.StreamVideoRequest{}, camera.TransportUSB, "")
	if err == nil {
		t.Fatal("expected error when gst-launch-1.0 not found")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected gRPC status error, got: %v", err)
	}
	if st.Code() != codes.FailedPrecondition {
		t.Errorf("expected FailedPrecondition, got %v", st.Code())
	}
}

// defaultElements approximates a system where x264enc + h264parse + webmmux
// + libcamerasrc are all installed. CSI tests delete individual entries.
func defaultElements() map[string]bool {
	return map[string]bool{
		"x264enc":      true,
		"h264parse":    true,
		"webmmux":      true,
		"vp8enc":       true,
		"libcamerasrc": true,
	}
}

// --- CSI / transport classification tests ---

func TestListV4L2Devices_UsbAndCsiMix(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0", "/dev/video1"}, nil },
		func(base string) (string, error) {
			return map[string]string{"video0": "USB Cam", "video1": "CSI Cam"}[base], nil
		},
	)
	svc.classifyTransport = func(base string) (camera.Transport, string) {
		switch base {
		case "video0":
			return camera.TransportUSB, "uvcvideo"
		case "video1":
			return camera.TransportCSI, "tegra-capture-vi"
		}
		return camera.TransportUnknown, ""
	}

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
	if devices[0].GetTransport() != agentpb.VideoTransport_VIDEO_TRANSPORT_USB || devices[0].GetDriver() != "uvcvideo" {
		t.Errorf("device 0 transport/driver wrong: %+v", devices[0])
	}
	if devices[1].GetTransport() != agentpb.VideoTransport_VIDEO_TRANSPORT_CSI || devices[1].GetDriver() != "tegra-capture-vi" {
		t.Errorf("device 1 transport/driver wrong: %+v", devices[1])
	}
}

func TestListV4L2Devices_CsiPopulatesLibcameraID(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(string) (string, error) { return "Ribbon", nil },
	)
	svc.classifyTransport = func(string) (camera.Transport, string) { return camera.TransportCSI, "tegra-capture-vi" }
	svc.enumerateLibcamera = func(context.Context) (map[string]string, error) {
		return map[string]string{"/base/soc/i2c/cam@1a": "Sensor"}, nil
	}

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if devices[0].GetLibcameraId() != "/base/soc/i2c/cam@1a" {
		t.Errorf("expected libcamera id to be set, got %q", devices[0].GetLibcameraId())
	}
}

func TestListV4L2Devices_AmbiguousLibcameraLeavesIDEmpty(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0", "/dev/video1"}, nil },
		func(string) (string, error) { return "Ribbon", nil },
	)
	svc.classifyTransport = func(string) (camera.Transport, string) { return camera.TransportCSI, "tegra-capture-vi" }
	svc.enumerateLibcamera = func(context.Context) (map[string]string, error) {
		return map[string]string{"/cam1": "A", "/cam2": "B"}, nil
	}

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, d := range devices {
		if d.GetLibcameraId() != "" {
			t.Errorf("expected empty libcamera id for ambiguous case, got %q on %s", d.GetLibcameraId(), d.GetPath())
		}
	}
}

func TestListV4L2Devices_LibcameraUnavailable_NoError(t *testing.T) {
	svc := newTestVideoService(
		func() ([]string, error) { return []string{"/dev/video0"}, nil },
		func(string) (string, error) { return "Cam", nil },
	)
	svc.classifyTransport = func(string) (camera.Transport, string) { return camera.TransportCSI, "tegra-capture-vi" }
	svc.enumerateLibcamera = func(context.Context) (map[string]string, error) { return nil, fmt.Errorf("no cam binary") }

	devices, err := svc.listV4L2Devices(context.Background())
	if err != nil {
		t.Fatalf("listV4L2Devices must not fail when libcamera enumeration errors: %v", err)
	}
	if devices[0].GetTransport() != agentpb.VideoTransport_VIDEO_TRANSPORT_CSI {
		t.Errorf("transport still must be classified: %+v", devices[0])
	}
	if devices[0].GetLibcameraId() != "" {
		t.Errorf("libcamera id must be empty when enumeration failed, got %q", devices[0].GetLibcameraId())
	}
}

func TestBuildGStreamerArgs_USB_UsesV4l2Src(t *testing.T) {
	args := buildGStreamerArgs("gst", "/dev/video0", &agentpb.StreamVideoRequest{}, "x264enc", true, camera.TransportUSB, "", defaultElements())
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "v4l2src device=/dev/video0") {
		t.Errorf("USB pipeline must use v4l2src: %v", args)
	}
	if strings.Contains(joined, "libcamerasrc") {
		t.Errorf("USB pipeline must not use libcamerasrc: %v", args)
	}
}

func TestBuildGStreamerArgs_CSI_UsesLibcamerasrc(t *testing.T) {
	args := buildGStreamerArgs("gst", "/dev/video0", &agentpb.StreamVideoRequest{}, "x264enc", true, camera.TransportCSI, "", defaultElements())
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "libcamerasrc") {
		t.Errorf("CSI pipeline must use libcamerasrc: %v", args)
	}
	if strings.Contains(joined, "v4l2src") {
		t.Errorf("CSI pipeline must not fall back to v4l2src when libcamerasrc is available: %v", args)
	}
}

func TestBuildGStreamerArgs_CSI_WithLibcameraID_AppendsCameraName(t *testing.T) {
	args := buildGStreamerArgs("gst", "/dev/video0", &agentpb.StreamVideoRequest{}, "x264enc", true, camera.TransportCSI, "/base/cam@1a", defaultElements())
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "libcamerasrc camera-name=/base/cam@1a") {
		t.Errorf("CSI pipeline with id must pass camera-name=...: %v", args)
	}
}

func TestBuildGStreamerArgs_CSI_LibcamerasrcMissing_FallsBackToV4l2(t *testing.T) {
	elems := defaultElements()
	delete(elems, "libcamerasrc")
	args := buildGStreamerArgs("gst", "/dev/video0", &agentpb.StreamVideoRequest{}, "x264enc", true, camera.TransportCSI, "/base/cam@1a", elems)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "v4l2src device=/dev/video0") {
		t.Errorf("CSI pipeline must fall back to v4l2src when libcamerasrc plugin is absent: %v", args)
	}
	if strings.Contains(joined, "libcamerasrc") {
		t.Errorf("CSI pipeline must not use libcamerasrc when plugin absent: %v", args)
	}
}

func TestBuildSourceElement_NilAvailableMapTreatedAsLibcamerasrcAbsent(t *testing.T) {
	src := buildSourceElement("/dev/video0", camera.TransportCSI, "/cam", nil)
	if src != "v4l2src device=/dev/video0" {
		t.Errorf("nil availability must degrade CSI to v4l2src, got %q", src)
	}
}

func TestUseArgusSource(t *testing.T) {
	withArgus := map[string]bool{"nvarguscamerasrc": true}
	cases := []struct {
		name      string
		transport camera.Transport
		isJetson  bool
		available map[string]bool
		want      bool
	}{
		{"csi jetson with plugin", camera.TransportCSI, true, withArgus, true},
		{"usb jetson with plugin", camera.TransportUSB, true, withArgus, false},
		{"csi non-jetson with plugin", camera.TransportCSI, false, withArgus, false},
		{"csi jetson no plugin", camera.TransportCSI, true, map[string]bool{}, false},
		{"csi jetson nil map", camera.TransportCSI, true, nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := useArgusSource(tc.transport, tc.isJetson, tc.available); got != tc.want {
				t.Errorf("useArgusSource(%v, %v, %v) = %v, want %v", tc.transport, tc.isJetson, tc.available, got, tc.want)
			}
		})
	}
}
