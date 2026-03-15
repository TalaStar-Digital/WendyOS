//go:build darwin || linux

package commands

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

func addOSCacheCmd(parent *cobra.Command) {
	cmd := &cobra.Command{
		Use:   "cache",
		Short: "Manage cached OS images",
	}

	cmd.AddCommand(newOSCacheListCmd())
	cmd.AddCommand(newOSCacheClearCmd())

	parent.AddCommand(cmd)
}

func newOSCacheListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List cached OS images",
		RunE: func(cmd *cobra.Command, args []string) error {
			dir, err := osCacheDir()
			if err != nil {
				return err
			}

			entries, err := os.ReadDir(dir)
			if err != nil {
				if os.IsNotExist(err) {
					fmt.Println("No cached OS images.")
					return nil
				}
				return fmt.Errorf("reading cache: %w", err)
			}

			var found bool
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				info, err := entry.Info()
				if err != nil {
					continue
				}
				sizeMB := float64(info.Size()) / (1024 * 1024)
				fmt.Printf("  %s  (%.1f MB)\n", entry.Name(), sizeMB)
				found = true
			}

			if !found {
				fmt.Println("No cached OS images.")
			} else {
				fmt.Printf("\nCache directory: %s\n", dir)
			}

			return nil
		},
	}
}

func newOSCacheClearCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "clear",
		Short: "Clear all cached OS images",
		RunE: func(cmd *cobra.Command, args []string) error {
			dir, err := osCacheDir()
			if err != nil {
				return err
			}

			entries, err := os.ReadDir(dir)
			if err != nil {
				if os.IsNotExist(err) {
					fmt.Println("Cache is already empty.")
					return nil
				}
				return fmt.Errorf("reading cache: %w", err)
			}

			var removed int
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				if err := os.Remove(filepath.Join(dir, entry.Name())); err == nil {
					removed++
				}
			}

			fmt.Printf("Cleared %d cached image(s).\n", removed)
			return nil
		},
	}
}
