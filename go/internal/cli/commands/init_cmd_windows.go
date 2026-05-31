//go:build windows

package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

func launchAssistantWithPrompt(choice, prompt string) error {
	tmpPath, cleanup, err := writePromptForAssistant(prompt)
	if err != nil {
		return err
	}
	defer cleanup()

	short := fmt.Sprintf("Read the Markdown file at this absolute path: %s for project context, then help me get started building this project.", tmpPath)

	cmd := exec.Command(choice, short)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func writePromptForAssistant(prompt string) (string, func(), error) {
	f, err := os.CreateTemp("", "wendy-init-prompt-*.md")
	if err != nil {
		return "", nil, fmt.Errorf("creating prompt temp file: %w", err)
	}
	path := f.Name()

	if _, err := f.WriteString(prompt); err != nil {
		f.Close()
		os.Remove(path)
		return "", nil, fmt.Errorf("writing prompt temp file: %w", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", nil, fmt.Errorf("closing prompt temp file: %w", err)
	}

	return path, func() { os.Remove(path) }, nil
}

func windowsRootDir() string {
	root, err := windows.GetWindowsDirectory()
	if err != nil || strings.TrimSpace(root) == "" || !filepath.IsAbs(root) {
		return `C:\Windows`
	}
	return filepath.Clean(root)
}

func isRootOwned(path string, _ os.FileInfo) bool {
	descriptor, err := windows.GetNamedSecurityInfo(filepath.Clean(path), windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil || descriptor == nil || !descriptor.IsValid() {
		return false
	}
	owner, _, err := descriptor.Owner()
	if err != nil || owner == nil || !owner.IsValid() {
		return false
	}
	return owner.IsWellKnown(windows.WinLocalSystemSid) || owner.IsWellKnown(windows.WinBuiltinAdministratorsSid)
}
