//go:build darwin

package discovery

import (
	"fmt"
	"path/filepath"
)

// ResolveESP32SerialPort finds the serial port for an ESP32-C6 device on macOS.
// It globs /dev/cu.usbmodem* and returns the first match.
func ResolveESP32SerialPort() (string, error) {
	matches, err := filepath.Glob("/dev/cu.usbmodem*")
	if err != nil {
		return "", fmt.Errorf("globbing serial ports: %w", err)
	}

	if len(matches) == 0 {
		return "", fmt.Errorf("no ESP32 serial port found (expected /dev/cu.usbmodem*)")
	}

	return matches[0], nil
}
