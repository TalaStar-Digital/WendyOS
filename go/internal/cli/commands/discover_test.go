package commands

import (
	"context"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/wendylabsinc/wendy/internal/shared/discovery"
	"github.com/wendylabsinc/wendy/internal/shared/models"
)

func TestParseDurationEnv(t *testing.T) {
	tests := []struct {
		name     string
		envVal   string
		fallback time.Duration
		want     time.Duration
	}{
		{"empty uses fallback", "", 3 * time.Second, 3 * time.Second},
		{"valid duration", "5s", 3 * time.Second, 5 * time.Second},
		{"valid ms", "500ms", 3 * time.Second, 500 * time.Millisecond},
		{"invalid uses fallback", "notaduration", 3 * time.Second, 3 * time.Second},
	}

	const testKey = "WENDY_TEST_PARSE_DURATION"
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.envVal != "" {
				t.Setenv(testKey, tt.envVal)
			}
			got := parseDurationEnv(testKey, tt.fallback)
			if got != tt.want {
				t.Errorf("parseDurationEnv(%q) = %v; want %v", tt.envVal, got, tt.want)
			}
		})
	}
}

func TestDelayThen(t *testing.T) {
	called := false
	inner := func() tea.Msg {
		called = true
		return "done"
	}

	// With zero delay the inner cmd should execute immediately.
	cmd := delayThen(0, inner)
	msg := cmd()
	if !called {
		t.Fatal("inner cmd was not called")
	}
	if msg != "done" {
		t.Errorf("msg = %v; want \"done\"", msg)
	}
}

func TestDelayThen_ActuallyDelays(t *testing.T) {
	inner := func() tea.Msg { return "done" }

	start := time.Now()
	cmd := delayThen(50*time.Millisecond, inner)
	cmd()
	elapsed := time.Since(start)

	if elapsed < 40*time.Millisecond {
		t.Errorf("delayThen returned too fast (%v); expected >= 50ms delay", elapsed)
	}
}

func TestDiscoverModel_UpdateReturnsDelayedCmd(t *testing.T) {
	// Save and restore poll intervals so the test doesn't depend on env vars.
	origUSB := usbPollInterval
	origEth := ethernetPollInterval
	origExt := externalPollInterval
	defer func() {
		usbPollInterval = origUSB
		ethernetPollInterval = origEth
		externalPollInterval = origExt
	}()

	// Use zero intervals so the test doesn't actually sleep.
	usbPollInterval = 0
	ethernetPollInterval = 0
	externalPollInterval = 0

	m := newDiscoverModel(context.Background(), defaultOpts())

	// Each scan message type should return a non-nil command (the delayed rescan).
	cases := []struct {
		name string
		msg  tea.Msg
	}{
		{"usb", usbScanMsg{devices: []models.USBDevice{{DisplayName: "test"}}}},
		{"ethernet", ethScanMsg{devices: []models.EthernetInterface{{DisplayName: "eth0"}}}},
		{"external", extScanMsg{devices: []models.ExternalDevice{{DisplayName: "ext0"}}}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			updated, cmd := m.Update(tc.msg)
			um := updated.(discoverModel)
			if !um.hasResults {
				t.Error("expected hasResults = true after scan message")
			}
			if cmd == nil {
				t.Error("expected non-nil cmd (delayed rescan)")
			}
		})
	}
}

func TestDiscoverModel_QuitOnKeyMsg(t *testing.T) {
	m := newDiscoverModel(context.Background(), defaultOpts())

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	um := updated.(discoverModel)
	if !um.quitting {
		t.Error("expected quitting = true after 'q' key")
	}
	if cmd == nil {
		t.Error("expected non-nil quit cmd")
	}
}

func TestDiscoverModel_Init(t *testing.T) {
	m := newDiscoverModel(context.Background(), defaultOpts())
	cmd := m.Init()
	if cmd == nil {
		t.Error("expected non-nil Init cmd (batch of scan commands)")
	}
}

func defaultOpts() discovery.DiscoveryOptions {
	return discovery.DiscoveryOptions{Timeout: time.Second}
}
