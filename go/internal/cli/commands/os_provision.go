package commands

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendy/internal/shared/wendyconf"
)

// writeConfigFiles writes the agent binary and optional wendy.conf to
// mountPoint. agentBinary is the raw binary content. When creds is empty no
// wendy.conf is produced; otherwise a multi-network INI is written.
func writeConfigFiles(mountPoint string, agentBinary []byte, creds []wendyconf.WifiCredential) error {
	binPath := filepath.Join(mountPoint, "wendy-agent")
	if err := os.WriteFile(binPath, agentBinary, 0o755); err != nil {
		return fmt.Errorf("writing wendy-agent to config partition: %w", err)
	}

	if len(creds) == 0 {
		return nil
	}

	for _, c := range creds {
		if strings.ContainsAny(c.SSID, "\n\r") || strings.ContainsAny(c.Password, "\n\r") {
			return fmt.Errorf("WiFi SSID and password must not contain newline characters")
		}
	}

	confPath := filepath.Join(mountPoint, "wendy.conf")
	if err := os.WriteFile(confPath, wendyconf.Marshal(creds), 0o644); err != nil {
		return fmt.Errorf("writing wendy.conf to config partition: %w", err)
	}
	return nil
}
