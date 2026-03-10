package env

import (
	"os"
	"strings"
	"time"
)

type envNamespace struct{}

// Env provides namespaced access to WENDY_* environment variables.
// Each method reads os.Getenv on every call — no caching.
var Env envNamespace

func (envNamespace) DiscoverUSBInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_USB_INTERVAL", 3*time.Second)
}

func (envNamespace) DiscoverEthernetInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_ETHERNET_INTERVAL", 3*time.Second)
}

func (envNamespace) DiscoverExternalInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_EXTERNAL_INTERVAL", 5*time.Second)
}

func (envNamespace) Analytics() bool {
	return !strings.EqualFold(os.Getenv("WENDY_ANALYTICS"), "false")
}

func (envNamespace) SystemdServiceName() string {
	return stringOrDefault("WENDY_SYSTEMD_SERVICE_NAME", "edge-agent")
}

func parseDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}

func stringOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return fallback
}
