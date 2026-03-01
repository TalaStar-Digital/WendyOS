package commands

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"github.com/wendylabsinc/wendy/internal/cli/tui"
	"github.com/wendylabsinc/wendy/internal/shared/discovery"
	"github.com/wendylabsinc/wendy/internal/shared/models"
)

func newDiscoverCmd() *cobra.Command {
	var discoverType string
	var timeout time.Duration

	cmd := &cobra.Command{
		Use:   "discover",
		Short: "Discover WendyOS devices on the network",
		RunE: func(cmd *cobra.Command, args []string) error {
			opts := discovery.DiscoveryOptions{
				Timeout: timeout,
			}

			switch discoverType {
			case "usb":
				opts.Types = []models.InterfaceType{models.InterfaceUSB}
			case "lan":
				opts.Types = []models.InterfaceType{models.InterfaceLAN}
			case "bluetooth":
				opts.Types = []models.InterfaceType{models.InterfaceBluetooth}
			case "all", "":
				// discover all types
			default:
				return fmt.Errorf("unknown discovery type: %s (valid: usb, lan, bluetooth, all)", discoverType)
			}

			if jsonOutput {
				return discoverJSON(cmd.Context(), opts)
			}
			return discoverInteractive(cmd.Context(), opts)
		},
	}

	cmd.Flags().StringVar(&discoverType, "type", "all", "Discovery type: usb, lan, bluetooth, all")
	cmd.Flags().DurationVar(&timeout, "timeout", 5*time.Second, "Discovery timeout duration")

	return cmd
}

func discoverJSON(ctx context.Context, opts discovery.DiscoveryOptions) error {
	collection, err := discovery.Discover(ctx, opts)
	if err != nil {
		return fmt.Errorf("discovery failed: %w", err)
	}

	data, err := json.MarshalIndent(collection, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling results: %w", err)
	}
	fmt.Println(string(data))
	return nil
}

func discoverInteractive(ctx context.Context, opts discovery.DiscoveryOptions) error {
	s := tui.NewSpinner("Scanning for WendyOS devices...")

	work := func() tea.Msg {
		collection, err := discovery.Discover(ctx, opts)
		return tui.SpinnerDoneMsg{Result: collection, Err: err}
	}

	p := tea.NewProgram(s)
	go func() {
		result := work()
		p.Send(result)
	}()

	finalModel, err := p.Run()
	if err != nil {
		return fmt.Errorf("TUI error: %w", err)
	}

	model := finalModel.(tui.SpinnerModel)
	result, spinErr := model.Result()
	if spinErr != nil {
		return spinErr
	}

	collection, ok := result.(*models.DevicesCollection)
	if !ok || collection == nil {
		fmt.Println("No devices found.")
		return nil
	}

	if collection.IsEmpty() {
		fmt.Println("No devices found.")
		return nil
	}

	// Render results as a styled table.
	headers := []string{"Name", "Type", "Address", "Version"}
	var rows [][]string

	for _, d := range collection.USBDevices {
		rows = append(rows, []string{d.DisplayName, "USB", d.Hostname, d.AgentVersion})
	}
	for _, d := range collection.LANDevices {
		addr := d.Hostname
		if d.IPAddress != "" {
			addr = d.IPAddress
		}
		rows = append(rows, []string{d.DisplayName, "LAN", addr, d.AgentVersion})
	}
	for _, d := range collection.BluetoothDevices {
		rows = append(rows, []string{d.DisplayName, "Bluetooth", d.Address, d.AgentVersion})
	}
	for _, d := range collection.EthernetInterfaces {
		rows = append(rows, []string{d.DisplayName, "Ethernet", d.IPAddress, d.AgentVersion})
	}

	fmt.Print(tui.RenderTable(headers, rows))
	return nil
}
