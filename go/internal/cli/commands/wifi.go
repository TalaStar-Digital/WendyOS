package commands

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"
	"github.com/wendylabsinc/wendy/internal/cli/tui"
	"github.com/wendylabsinc/wendy/proto/gen/agentpb"
)

func newWifiCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "wifi",
		Short: "Manage WiFi on the target device",
	}

	cmd.AddCommand(
		newWifiListCmd(),
		newWifiConnectCmd(),
		newWifiStatusCmd(),
		newWifiDisconnectCmd(),
	)

	return cmd
}

func newWifiListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List available WiFi networks",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			conn, err := connectToAgent(ctx)
			if err != nil {
				return err
			}
			defer conn.Close()

			resp, err := conn.AgentService.ListWiFiNetworks(ctx, &agentpb.ListWiFiNetworksRequest{})
			if err != nil {
				return fmt.Errorf("listing WiFi networks: %w", err)
			}

			networks := resp.GetNetworks()
			if jsonOutput {
				data, err := json.MarshalIndent(networks, "", "  ")
				if err != nil {
					return err
				}
				fmt.Println(string(data))
				return nil
			}

			if len(networks) == 0 {
				fmt.Println("No WiFi networks found.")
				return nil
			}

			headers := []string{"SSID", "Signal"}
			var rows [][]string
			for _, n := range networks {
				rows = append(rows, []string{
					n.GetSsid(),
					fmt.Sprintf("%d%%", n.GetSignalStrength()),
				})
			}
			fmt.Print(tui.RenderTable(headers, rows))
			return nil
		},
	}
}

func newWifiConnectCmd() *cobra.Command {
	var ssid string
	var password string

	cmd := &cobra.Command{
		Use:   "connect",
		Short: "Connect to a WiFi network",
		RunE: func(cmd *cobra.Command, args []string) error {
			if ssid == "" {
				return fmt.Errorf("--ssid is required")
			}

			ctx := cmd.Context()
			conn, err := connectToAgent(ctx)
			if err != nil {
				return err
			}
			defer conn.Close()

			resp, err := conn.AgentService.ConnectToWiFi(ctx, &agentpb.ConnectToWiFiRequest{
				Ssid:     ssid,
				Password: password,
			})
			if err != nil {
				return fmt.Errorf("connecting to WiFi: %w", err)
			}

			if !resp.GetSuccess() {
				return fmt.Errorf("failed to connect: %s", resp.GetErrorMessage())
			}

			fmt.Printf("Connected to %s\n", ssid)
			return nil
		},
	}

	cmd.Flags().StringVar(&ssid, "ssid", "", "WiFi network SSID")
	cmd.Flags().StringVar(&password, "password", "", "WiFi network password")

	return cmd
}

func newWifiStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Get current WiFi connection status",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			conn, err := connectToAgent(ctx)
			if err != nil {
				return err
			}
			defer conn.Close()

			resp, err := conn.AgentService.GetWiFiStatus(ctx, &agentpb.GetWiFiStatusRequest{})
			if err != nil {
				return fmt.Errorf("getting WiFi status: %w", err)
			}

			if jsonOutput {
				data, err := json.MarshalIndent(map[string]interface{}{
					"connected": resp.GetConnected(),
					"ssid":      resp.GetSsid(),
				}, "", "  ")
				if err != nil {
					return err
				}
				fmt.Println(string(data))
				return nil
			}

			if resp.GetConnected() {
				fmt.Printf("Connected to: %s\n", resp.GetSsid())
			} else {
				fmt.Println("Not connected to any WiFi network.")
			}
			return nil
		},
	}
}

func newWifiDisconnectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "disconnect",
		Short: "Disconnect from the current WiFi network",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			conn, err := connectToAgent(ctx)
			if err != nil {
				return err
			}
			defer conn.Close()

			resp, err := conn.AgentService.DisconnectWiFi(ctx, &agentpb.DisconnectWiFiRequest{})
			if err != nil {
				return fmt.Errorf("disconnecting WiFi: %w", err)
			}

			if !resp.GetSuccess() {
				return fmt.Errorf("failed to disconnect: %s", resp.GetErrorMessage())
			}

			fmt.Println("Disconnected from WiFi.")
			return nil
		},
	}
}
