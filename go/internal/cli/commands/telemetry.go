package commands

import "github.com/spf13/cobra"

func newTelemetryCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "telemetry",
		Short: "Stream telemetry data from the target device",
	}

	logsCmd := newDeviceLogsCmd()
	logsCmd.Use = "logs"

	streamCmd := newDeviceTelemetryStreamCmd()
	streamCmd.Use = "stream"
	streamCmd.Short = "Stream telemetry data as JSONL"

	cmd.AddCommand(
		logsCmd,
		streamCmd,
	)

	return cmd
}
