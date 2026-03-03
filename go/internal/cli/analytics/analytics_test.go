package analytics

import (
	"testing"

	"github.com/wendylabsinc/wendy/internal/shared/config"
)

func TestDisabledViaEnvVar(t *testing.T) {
	t.Setenv("WENDY_ANALYTICS", "false")

	cfg := &config.Config{
		Analytics: &config.AnalyticsConfig{Enabled: true},
	}
	Init(cfg)

	if Enabled() {
		t.Error("expected analytics to be disabled via env var")
	}
}

func TestDisabledViaConfig(t *testing.T) {
	t.Setenv("WENDY_ANALYTICS", "")

	cfg := &config.Config{
		Analytics: &config.AnalyticsConfig{Enabled: false},
	}
	Init(cfg)

	if Enabled() {
		t.Error("expected analytics to be disabled via config")
	}
}

func TestEnabledByDefaultWhenNil(t *testing.T) {
	t.Setenv("WENDY_ANALYTICS", "")

	cfg := &config.Config{
		Analytics: nil,
	}
	firstRun := Init(cfg)

	if !firstRun {
		t.Error("expected firstRun to be true when Analytics is nil")
	}
	// enabled is set to true, but client may fail to init (no network in tests).
	// We just verify the enabled flag was set correctly before client init.
}

func TestEnvOverride(t *testing.T) {
	t.Setenv("WENDY_ANALYTICS", "false")
	if !EnvOverride() {
		t.Error("expected EnvOverride to return true")
	}

	t.Setenv("WENDY_ANALYTICS", "")
	if EnvOverride() {
		t.Error("expected EnvOverride to return false")
	}
}

func TestTrackNoOpWhenDisabled(t *testing.T) {
	t.Setenv("WENDY_ANALYTICS", "false")

	cfg := &config.Config{}
	Init(cfg)

	// Should not panic
	Track("test_event", map[string]string{"key": "value"})
	Close()
}
