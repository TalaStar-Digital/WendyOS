package main

import (
	"fmt"
	"os"

	"github.com/wendylabsinc/wendy/internal/cli/commands"
)

func main() {
	cmd := commands.NewRootCmd()
	if err := cmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
