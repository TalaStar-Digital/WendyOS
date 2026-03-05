//go:build !darwin && !linux

package commands

import "github.com/spf13/cobra"

func addOSInstallCmd(_ *cobra.Command) {
	// os install is not supported on this platform.
}
