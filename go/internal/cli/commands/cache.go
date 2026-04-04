package commands

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/wendylabsinc/wendy/internal/cli/tui"
	"github.com/wendylabsinc/wendy/internal/shared/config"
)

func newCacheCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "cache",
		Short: "Manage local CLI cache",
	}

	cmd.AddCommand(
		newCacheListCmd(),
		newCacheClearCmd(),
	)

	return cmd
}

func newCacheListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List cached items",
		RunE: func(cmd *cobra.Command, args []string) error {
			cacheDir, err := config.CacheDir()
			if err != nil {
				return err
			}

			entries, err := os.ReadDir(cacheDir)
			if err != nil {
				if os.IsNotExist(err) {
					fmt.Println("Cache is empty.")
					return nil
				}
				return fmt.Errorf("reading cache directory: %w", err)
			}

			if len(entries) == 0 {
				fmt.Println("Cache is empty.")
				return nil
			}

			// Compute sizes up front (needed for both modes).
			// The os-images directory is expanded so each image is listed individually.
			type cacheEntry struct {
				name string
				path string
				size int64
			}
			var items []cacheEntry
			for _, entry := range entries {
				if isCacheDBFile(entry.Name()) {
					continue
				}
				path := filepath.Join(cacheDir, entry.Name())
				if entry.IsDir() && entry.Name() == "os-images" {
					imgs, err := os.ReadDir(path)
					if err == nil {
						for _, img := range imgs {
							if img.IsDir() {
								continue
							}
							imgPath := filepath.Join(path, img.Name())
							imgInfo, err := img.Info()
							var imgSize int64
							if err == nil {
								imgSize = imgInfo.Size()
							}
							items = append(items, cacheEntry{
								name: "os-images/" + img.Name(),
								path: imgPath,
								size: imgSize,
							})
						}
					}
					continue
				}
				size, err := entrySize(path)
				if err != nil {
					size = 0
				}
				items = append(items, cacheEntry{name: entry.Name(), path: path, size: size})
			}

			// Interactive mode when stdout is a terminal.
			if term.IsTerminal(int(os.Stdout.Fd())) {
				checkItems := make([]tui.ChecklistItem, len(items))
				for i, item := range items {
					checkItems[i] = tui.ChecklistItem{
						Label:       item.name,
						Description: formatSize(item.size),
						Value:       item.path,
					}
				}

				cl := tui.NewChecklist("Select cache entries to delete:", checkItems)
				cl.SelectAllLabel = "Delete all"
				selected, err := tui.RunChecklistModel(cl, tea.WithOutput(os.Stderr))
				if err != nil {
					return nil // cancelled
				}
				if len(selected) == 0 {
					return nil
				}

				confirmed, err := tui.Confirm(fmt.Sprintf("Delete %d item(s)?", len(selected)), tea.WithOutput(os.Stderr))
				if err != nil || !confirmed {
					return nil
				}

				for _, item := range selected {
					if err := os.RemoveAll(item.Value); err != nil {
						fmt.Fprintf(os.Stderr, "error: removing %s: %v\n", item.Label, err)
					} else {
						fmt.Printf("Deleted %s\n", item.Label)
					}
				}
				return nil
			}

			// Non-interactive (plain listing).
			for _, item := range items {
				fmt.Printf("  %s  (%s)\n", item.name, formatSize(item.size))
			}
			return nil
		},
	}
}

// isCacheDBFile returns true for SQLite database files that back the CLI cache
// and must not be removed while the process is running.
func isCacheDBFile(name string) bool {
	switch name {
	case "Cache.db", "Cache.db-shm", "Cache.db-wal":
		return true
	}
	return false
}

func entrySize(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			total += info.Size()
		}
		return nil
	})
	return total, err
}

func formatSize(bytes int64) string {
	const (
		KB = 1024
		MB = 1024 * KB
		GB = 1024 * MB
	)
	switch {
	case bytes >= GB:
		return fmt.Sprintf("%.1f GB", float64(bytes)/GB)
	case bytes >= MB:
		return fmt.Sprintf("%.1f MB", float64(bytes)/MB)
	case bytes >= KB:
		return fmt.Sprintf("%.1f KB", float64(bytes)/KB)
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

func newCacheClearCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "clear",
		Short: "Clear the local cache",
		RunE: func(cmd *cobra.Command, args []string) error {
			cacheDir, err := config.CacheDir()
			if err != nil {
				return err
			}

			if err := os.RemoveAll(cacheDir); err != nil {
				return fmt.Errorf("clearing cache: %w", err)
			}

			fmt.Println("Cache cleared.")
			return nil
		},
	}
}
