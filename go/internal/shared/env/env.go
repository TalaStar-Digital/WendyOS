package env

import (
	"log"
	"os"
	"strings"
	"time"
)

func DiscoverUSBInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_USB_INTERVAL", 3*time.Second)
}

func DiscoverEthernetInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_ETHERNET_INTERVAL", 3*time.Second)
}

func DiscoverExternalInterval() time.Duration {
	return parseDuration("WENDY_DISCOVER_EXTERNAL_INTERVAL", 5*time.Second)
}

func Analytics() bool {
	return !strings.EqualFold(os.Getenv("WENDY_ANALYTICS"), "false")
}

func SystemdServiceName() string {
	return stringOrDefault("WENDY_SYSTEMD_SERVICE_NAME", "edge-agent")
}

func parseDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Printf("WARNING: invalid %s=%q, using default %s", key, v, fallback)
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
