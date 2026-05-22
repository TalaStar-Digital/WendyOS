package commands

import (
	"bytes"
	"strings"
	"testing"
)

func TestAnalyticsCommand_HasSubcommands(t *testing.T) {
	cmd := newAnalyticsCmd()

	expectedSubcmds := []string{"enable", "disable", "status"}
	cmds := cmd.Commands()
	cmdNames := make(map[string]bool)
	for _, c := range cmds {
		cmdNames[c.Name()] = true
	}

	for _, name := range expectedSubcmds {
		if !cmdNames[name] {
			t.Errorf("missing subcommand %q", name)
		}
	}
}

func TestAnalyticsCommand_StatusOutput(t *testing.T) {
	root := NewRootCmd()
	buf := new(bytes.Buffer)
	root.SetOut(buf)
	root.SetErr(buf)
	root.SetArgs([]string{"analytics", "status"})

	// Set env to get predictable output and avoid writing to real home.
	t.Setenv("WENDY_ANALYTICS", "false")
	t.Setenv("HOME", t.TempDir())

	err := root.Execute()
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "disabled") {
		t.Errorf("expected 'disabled' in output, got: %q", output)
	}
}
