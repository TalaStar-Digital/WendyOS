//go:build darwin || linux || windows

package commands

import (
	"archive/zip"
	"bytes"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendy/internal/shared/version"
)

func TestNewOSInstallCmd_Flags(t *testing.T) {
	cmd := newOSInstallCmd()
	if cmd.Use != "install [image] [drive]" {
		t.Errorf("Use = %q; want %q", cmd.Use, "install [image] [drive]")
	}

	expectedFlags := []string{"nightly", "force", "device-type", "version", "drive", "wifi-ssid", "wifi-password", "wifi", "no-wifi", "device-name"}
	for _, name := range expectedFlags {
		if cmd.Flags().Lookup(name) == nil {
			t.Errorf("missing flag %q", name)
		}
	}
}

func TestNewOSInstallCmd_NightlyVersionMutualExclusion(t *testing.T) {
	cmd := newOSInstallCmd()
	cmd.SetArgs([]string{"--nightly", "--version", "0.10.0"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error when --nightly and --version are both set")
	}
	if got := err.Error(); got != "--nightly and --version are mutually exclusive" {
		t.Errorf("unexpected error: %q", got)
	}
}

func TestNewOSInstallCmd_PositionalArgsIncompatibleWithFlags(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{"positional with --device-type", []string{"image.img", "/dev/disk4", "--device-type", "raspberry-pi-5", "--force"}},
		{"positional with --version", []string{"image.img", "/dev/disk4", "--version", "0.10.0", "--force"}},
		{"positional with --drive", []string{"image.img", "/dev/disk4", "--drive", "/dev/disk5", "--force"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cmd := newOSInstallCmd()
			cmd.SetArgs(tc.args)
			err := cmd.Execute()
			if err == nil {
				t.Fatal("expected error when positional args are combined with manifest flags")
			}
			expected := "positional [image] [drive] arguments cannot be combined with --device-type, --version, --drive, --wifi-ssid, --wifi-password, --wifi, --no-wifi, or --device-name"
			if got := err.Error(); got != expected {
				t.Errorf("unexpected error: %q; want %q", got, expected)
			}
		})
	}
}

func TestNewOSInstallCmd_SinglePositionalArgRejected(t *testing.T) {
	cmd := newOSInstallCmd()
	cmd.SetArgs([]string{"image.img"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error when exactly 1 positional arg is provided")
	}
	expected := "positional arguments must be provided as [image] [drive]; got 1 argument"
	if got := err.Error(); got != expected {
		t.Errorf("unexpected error: %q; want %q", got, expected)
	}
}

func TestNewOSInstallCmd_ESP32DeviceTypeRejected(t *testing.T) {
	for _, dt := range []string{"esp32-c6", "esp32-c5"} {
		t.Run(dt, func(t *testing.T) {
			cmd := newOSInstallCmd()
			cmd.SetArgs([]string{"--device-type", dt})
			err := cmd.Execute()
			if err == nil {
				t.Fatal("expected error for ESP32 --device-type")
			}
			if !strings.Contains(err.Error(), "does not support ESP32") {
				t.Errorf("unexpected error: %q", err.Error())
			}
		})
	}
}

func TestPickManifestVersion_SemverOrdering(t *testing.T) {
	// Verify that version keys are sorted semantically, not lexicographically.
	// "0.10.0" should come after "0.9.0" semantically but before it lexicographically.
	versions := []string{"0.2.0", "0.10.0", "0.9.0", "0.1.0", "0.10.1"}

	// Use the same sorting logic as pickManifestVersion.
	sorted := make([]string, len(versions))
	copy(sorted, versions)
	sortFunc := func(i, j int) bool {
		return version.CompareVersions(sorted[i], sorted[j]) > 0
	}

	// Simple bubble sort for testing.
	for i := 0; i < len(sorted); i++ {
		for j := i + 1; j < len(sorted); j++ {
			if !sortFunc(i, j) {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}

	expected := []string{"0.10.1", "0.10.0", "0.9.0", "0.2.0", "0.1.0"}
	for i, v := range sorted {
		if v != expected[i] {
			t.Errorf("sorted[%d] = %q; want %q (full: %v)", i, v, expected[i], sorted)
			break
		}
	}
}

func TestOsCachedImagePath_Sanitization(t *testing.T) {
	// Valid inputs should produce a valid path.
	path, err := osCachedImagePath("raspberry-pi-5", "0.10.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if path == "" {
		t.Fatal("expected non-empty path")
	}

	// Path traversal in version should be rejected.
	_, err = osCachedImagePath("raspberry-pi-5", "../../../etc/passwd")
	if err == nil {
		t.Fatal("expected error for path traversal in version")
	}

	// Path traversal in device key should be rejected.
	_, err = osCachedImagePath("../evil", "0.10.4")
	if err == nil {
		t.Fatal("expected error for path traversal in device key")
	}
}

func TestOsCachedZipPath_Sanitization(t *testing.T) {
	path, err := osCachedZipPath("raspberry-pi-5", "0.10.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasSuffix(path, ".zip") {
		t.Fatalf("expected .zip suffix, got %q", path)
	}

	_, err = osCachedZipPath("raspberry-pi-5", "../../../etc/passwd")
	if err == nil {
		t.Fatal("expected error for path traversal in version")
	}

	_, err = osCachedZipPath("../evil", "0.10.4")
	if err == nil {
		t.Fatal("expected error for path traversal in device key")
	}
}

func makeTestZip(t *testing.T, entryName string, content []byte) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "test-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	w := zip.NewWriter(f)
	fw, err := w.Create(entryName)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return f.Name()
}

func TestStreamZipImageEntry(t *testing.T) {
	content := []byte("fake image data 12345")

	t.Run("reads img entry", func(t *testing.T) {
		zipPath := makeTestZip(t, "wendyos.img", content)
		r, size, err := streamZipImageEntry(zipPath)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		defer r.Close()
		if size != int64(len(content)) {
			t.Errorf("size = %d; want %d", size, len(content))
		}
		got, err := io.ReadAll(r)
		if err != nil {
			t.Fatalf("reading: %v", err)
		}
		if !bytes.Equal(got, content) {
			t.Errorf("content mismatch")
		}
	})

	t.Run("reads raw entry", func(t *testing.T) {
		zipPath := makeTestZip(t, "wendyos.raw", content)
		r, _, err := streamZipImageEntry(zipPath)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		r.Close()
	})

	t.Run("reads wic entry", func(t *testing.T) {
		zipPath := makeTestZip(t, "wendyos.wic", content)
		r, _, err := streamZipImageEntry(zipPath)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		r.Close()
	})

	t.Run("no image entry returns error", func(t *testing.T) {
		zipPath := makeTestZip(t, "readme.txt", content)
		_, _, err := streamZipImageEntry(zipPath)
		if err == nil {
			t.Fatal("expected error for zip with no image entry")
		}
	})

	t.Run("nonexistent file returns error", func(t *testing.T) {
		_, _, err := streamZipImageEntry("/nonexistent/path/image.zip")
		if err == nil {
			t.Fatal("expected error for nonexistent file")
		}
	})
}

func TestParseWiFiEntry(t *testing.T) {
	tests := []struct {
		name     string
		in       string
		wantSSID string
		wantPW   string
		wantPri  int32
		wantHid  bool
		wantSec  string
		wantErr  bool
	}{
		{"ssid only", "ssid=Home", "Home", "", 0, false, "", false},
		{"all fields", "ssid=Home,password=p,priority=10,hidden=true,security=wpa3", "Home", "p", 10, true, "wpa3", false},
		{"escaped comma", `ssid=My\,Net,password=x`, "My,Net", "x", 0, false, "", false},
		{"missing ssid", "password=p", "", "", 0, false, "", true},
		{"bad priority", "ssid=A,priority=nope", "", "", 0, false, "", true},
		{"unknown key", "ssid=A,foo=bar", "", "", 0, false, "", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c, err := parseWiFiEntry(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %+v", c)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if c.SSID != tc.wantSSID || c.Password != tc.wantPW || c.Priority != tc.wantPri || c.Hidden != tc.wantHid || c.Security != tc.wantSec {
				t.Errorf("got %+v; want ssid=%q pw=%q pri=%d hidden=%v sec=%q",
					c, tc.wantSSID, tc.wantPW, tc.wantPri, tc.wantHid, tc.wantSec)
			}
		})
	}
}

func TestResolveWiFiCredentialsListFlags(t *testing.T) {
	// --wifi-ssid + --wifi-password shortcut (non-TTY path: isInteractiveTerminal returns false in tests).
	creds, err := resolveWiFiCredentialsList(wifiCLIOptions{SSID: "Home", Password: "pw"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(creds) != 1 || creds[0].SSID != "Home" || creds[0].Password != "pw" {
		t.Errorf("shortcut produced %+v", creds)
	}

	// Repeatable --wifi: order preserved, priorities honoured.
	creds, err = resolveWiFiCredentialsList(wifiCLIOptions{Entries: []string{
		"ssid=First,password=a,priority=100",
		"ssid=Second,priority=50",
		"ssid=Hidden,hidden=true",
	}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(creds) != 3 {
		t.Fatalf("got %d creds; want 3", len(creds))
	}
	if creds[0].SSID != "First" || creds[0].Priority != 100 {
		t.Errorf("creds[0] = %+v", creds[0])
	}
	if creds[2].SSID != "Hidden" || !creds[2].Hidden {
		t.Errorf("creds[2] = %+v", creds[2])
	}

	// --no-wifi short-circuits even when other flags are empty.
	creds, err = resolveWiFiCredentialsList(wifiCLIOptions{NoWifi: true})
	if err != nil || creds != nil {
		t.Errorf("no-wifi: got %v, %+v", err, creds)
	}

	// --no-wifi combined with --wifi-ssid should error.
	if _, err := resolveWiFiCredentialsList(wifiCLIOptions{NoWifi: true, SSID: "Home"}); err == nil {
		t.Error("expected error when --no-wifi is combined with --wifi-ssid")
	}

	// --wifi-password without --wifi-ssid should error.
	if _, err := resolveWiFiCredentialsList(wifiCLIOptions{Password: "pw"}); err == nil {
		t.Error("expected error when --wifi-password is passed alone")
	}
}

func TestResolveOSImage_ZipCacheHit(t *testing.T) {
	content := []byte("fake image bytes")
	zipPath, err := osCachedZipPath("test-device", "9.9.9")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(zipPath)

	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	fw, _ := w.Create("image.img")
	fw.Write(content) //nolint:errcheck
	w.Close()
	f.Close()

	img := &imageInfo{Version: "9.9.9", DownloadURL: "https://example.com/image.zip"}
	got, err := resolveOSImage("test-device", img)
	if err != nil {
		t.Fatalf("resolveOSImage: %v", err)
	}
	if got != zipPath {
		t.Errorf("got %q; want %q", got, zipPath)
	}
}

func TestResolveOSImage_LegacyImgCacheHit(t *testing.T) {
	imgPath, err := osCachedImagePath("test-device", "8.8.8")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(imgPath)

	if err := os.WriteFile(imgPath, []byte("legacydata"), 0o644); err != nil {
		t.Fatal(err)
	}

	img := &imageInfo{Version: "8.8.8", DownloadURL: "https://example.com/image.zip"}
	got, err := resolveOSImage("test-device", img)
	if err != nil {
		t.Fatalf("resolveOSImage: %v", err)
	}
	if got != imgPath {
		t.Errorf("got %q; want %q (legacy img cache)", got, imgPath)
	}
}

func TestOpenOSImageStream_ZipCacheHit(t *testing.T) {
	content := []byte("stream me please")
	zipPath, err := osCachedZipPath("stream-device", "7.7.7")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(zipPath)

	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	fw, _ := w.Create("wendyos.img")
	fw.Write(content) //nolint:errcheck
	w.Close()
	f.Close()

	img := &imageInfo{Version: "7.7.7", DownloadURL: "https://example.com/image.zip"}
	r, size, err := openOSImageStream("stream-device", img)
	if err != nil {
		t.Fatalf("openOSImageStream: %v", err)
	}
	defer r.Close()

	if size != int64(len(content)) {
		t.Errorf("size = %d; want %d", size, len(content))
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Error("content mismatch")
	}
}

func TestOpenOSImageStream_LegacyImgCacheHit(t *testing.T) {
	content := []byte("old img cache data")
	imgPath, err := osCachedImagePath("legacy-device", "6.6.6")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(imgPath)

	if err := os.WriteFile(imgPath, content, 0o644); err != nil {
		t.Fatal(err)
	}

	img := &imageInfo{Version: "6.6.6", DownloadURL: "https://example.com/image.zip"}
	r, size, err := openOSImageStream("legacy-device", img)
	if err != nil {
		t.Fatalf("openOSImageStream: %v", err)
	}
	defer r.Close()

	if size != int64(len(content)) {
		t.Errorf("size = %d; want %d", size, len(content))
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Error("content mismatch")
	}
}
