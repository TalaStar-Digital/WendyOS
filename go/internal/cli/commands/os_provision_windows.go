//go:build windows

package commands

import (
	"fmt"

	"github.com/wendylabsinc/wendy/internal/shared/wendyconf"
)

func writeConfigPartition(d drive, agentBinary []byte, creds []wendyconf.WifiCredential) error {
	return fmt.Errorf("config partition provisioning is not supported on Windows")
}

func ejectDisk(_ string) {}
