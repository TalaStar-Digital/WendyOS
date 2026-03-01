package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"github.com/wendylabsinc/wendy/internal/cli/tui"
	"github.com/wendylabsinc/wendy/internal/shared/appconfig"
)

func newBuildCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "build",
		Short: "Build the application in the current directory",
		Long:  "Detects the project type and builds a Docker image for linux/arm64.",
		RunE: func(cmd *cobra.Command, args []string) error {
			cwd, err := os.Getwd()
			if err != nil {
				return fmt.Errorf("getting working directory: %w", err)
			}

			// Try to load wendy.json for language hints.
			var language string
			cfgPath := filepath.Join(cwd, "wendy.json")
			if appCfg, loadErr := appconfig.LoadFromFile(cfgPath); loadErr == nil {
				language = appCfg.Language
			}

			// Detect project type: prefer wendy.json language, then filesystem heuristics.
			projectType := detectProjectTypeWithLanguage(cwd, language)
			return buildProject(cmd.Context(), cwd, projectType)
		},
	}

	return cmd
}

// detectProjectTypeWithLanguage determines the project type using the wendy.json
// language field as a hint, falling back to filesystem detection.
func detectProjectTypeWithLanguage(dir, language string) string {
	// If wendy.json specifies a language, use that.
	switch language {
	case "python":
		return "python"
	case "swift":
		return "swift"
	}
	// Fall back to filesystem detection.
	return detectProjectType(dir)
}

func buildProject(ctx interface{ Done() <-chan struct{} }, dir, projectType string) error {
	imageName := filepath.Base(dir) + ":latest"

	switch projectType {
	case "docker":
		return buildDockerProject(dir, imageName)
	case "python":
		return buildPythonProject(dir, imageName)
	case "swift":
		return buildSwiftProject(dir)
	default:
		return fmt.Errorf("unknown project type; add a Dockerfile, Package.swift, or requirements.txt")
	}
}

func buildDockerProject(dir, imageName string) error {
	fmt.Printf("Building Docker image %s for linux/arm64...\n", imageName)

	s := tui.NewSpinner("Building Docker image...")
	p := tea.NewProgram(s)

	go func() {
		cmd := exec.Command("docker", "buildx", "build",
			"--platform", "linux/arm64",
			"-t", imageName,
			"--load",
			".")
		cmd.Dir = dir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		err := cmd.Run()
		p.Send(tui.SpinnerDoneMsg{Err: err})
	}()

	finalModel, err := p.Run()
	if err != nil {
		return fmt.Errorf("TUI error: %w", err)
	}

	model := finalModel.(tui.SpinnerModel)
	_, buildErr := model.Result()
	if buildErr != nil {
		return buildErr
	}

	fmt.Println("Build completed successfully.")
	return nil
}

func buildPythonProject(dir, imageName string) error {
	// If there is no Dockerfile, generate one.
	dockerfilePath := filepath.Join(dir, "Dockerfile")
	generatedDockerfile := false
	if _, err := os.Stat(dockerfilePath); os.IsNotExist(err) {
		fmt.Println("No Dockerfile found. Generating one for Python project...")
		if _, genErr := generatePythonDockerfile(dir); genErr != nil {
			return fmt.Errorf("generating Dockerfile: %w", genErr)
		}
		generatedDockerfile = true
		fmt.Println("Generated Dockerfile.")
	}

	err := buildDockerProject(dir, imageName)

	// Clean up generated Dockerfile if we created it.
	if generatedDockerfile {
		os.Remove(dockerfilePath)
	}

	return err
}

func buildSwiftProject(dir string) error {
	// For Swift projects, check for a Dockerfile first.
	if _, err := os.Stat(filepath.Join(dir, "Dockerfile")); err == nil {
		return buildDockerProject(dir, filepath.Base(dir)+":latest")
	}

	// Fall back to swift build (local, not cross-compiled).
	fmt.Println("Building Swift project locally...")
	s := tui.NewSpinner("Building Swift project...")
	p := tea.NewProgram(s)

	go func() {
		cmd := exec.Command("swift", "build")
		cmd.Dir = dir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		err := cmd.Run()
		p.Send(tui.SpinnerDoneMsg{Err: err})
	}()

	finalModel, err := p.Run()
	if err != nil {
		return fmt.Errorf("TUI error: %w", err)
	}

	model := finalModel.(tui.SpinnerModel)
	_, buildErr := model.Result()
	if buildErr != nil {
		return buildErr
	}

	fmt.Println("Build completed successfully.")
	return nil
}
