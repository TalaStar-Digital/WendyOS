// Package analytics provides anonymous usage tracking via PostHog.
package analytics

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/google/uuid"
	"github.com/posthog/posthog-go"
	"github.com/wendylabsinc/wendy/internal/shared/config"
	"github.com/wendylabsinc/wendy/internal/shared/env"
	"github.com/wendylabsinc/wendy/internal/shared/version"
)

const (
	posthogAPIKey = "phc_DCgbsvbGPdGhU6GW3CQnEwGCsNNrAHYwMhj4HkhjU4f"
	posthogHost   = "https://us.i.posthog.com"
)

var (
	client     posthog.Client
	enabled    bool
	distinctID string
)

// Init initializes analytics. If disabled by env var, config, or missing API key,
// tracking is a no-op. Returns true if this is the first run (config.Analytics
// was nil) AND the env var does not override, so the caller can display a notice.
func Init(cfg *config.Config) (firstRun bool) {
	// Env var overrides everything
	if !env.Analytics() {
		enabled = false
		return false
	}

	// First run: Analytics is nil
	if cfg.Analytics == nil {
		firstRun = true
		enabled = true
	} else {
		enabled = cfg.Analytics.Enabled
	}

	if !enabled {
		return firstRun
	}

	var err error
	distinctID, err = loadOrCreateID()
	if err != nil {
		enabled = false
		return firstRun
	}

	client, err = posthog.NewWithConfig(posthogAPIKey, posthog.Config{
		Endpoint: posthogHost,
		Logger:   posthog.StdLogger(log.New(io.Discard, "", 0), false),
	})
	if err != nil {
		enabled = false
		return firstRun
	}

	return firstRun
}

// Track sends an analytics event. No-op if analytics is disabled.
func Track(event string, properties map[string]string) {
	if !enabled || client == nil {
		return
	}

	props := posthog.NewProperties()
	props.Set("cli_version", version.Version)
	props.Set("os", runtime.GOOS)
	props.Set("arch", runtime.GOARCH)
	for k, v := range properties {
		props.Set(k, v)
	}

	_ = client.Enqueue(posthog.Capture{
		DistinctId: distinctID,
		Event:      event,
		Properties: props,
	})
}

// Close flushes pending events and shuts down the client.
func Close() {
	if client != nil {
		_ = client.Close()
		client = nil
	}
}

// Disable turns off analytics for the current process and closes the client.
func Disable() {
	enabled = false
	Close()
}

// Enabled reports whether analytics is currently enabled.
func Enabled() bool {
	return enabled
}

// EnvOverride reports whether the WENDY_ANALYTICS env var is set to "false".
func EnvOverride() bool {
	return !env.Analytics()
}

func loadOrCreateID() (string, error) {
	dir, err := config.ConfigDir()
	if err != nil {
		return "", err
	}

	idPath := filepath.Join(dir, "analytics_id")
	data, err := os.ReadFile(idPath)
	if err == nil {
		id := strings.TrimSpace(string(data))
		if id != "" {
			return id, nil
		}
	}

	id := uuid.NewString()
	if err := os.WriteFile(idPath, []byte(id), 0o600); err != nil {
		return "", fmt.Errorf("writing analytics ID: %w", err)
	}
	return id, nil
}
