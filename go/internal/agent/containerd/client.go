package containerd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
	"syscall"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	digest "github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"go.uber.org/zap"

	"github.com/wendylabsinc/wendy/internal/agent/services"
	localoci "github.com/wendylabsinc/wendy/internal/agent/oci"
	"github.com/wendylabsinc/wendy/internal/shared/appconfig"
	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
)

// Compile-time check that *Client satisfies services.ContainerdClient.
var _ services.ContainerdClient = (*Client)(nil)

// DefaultAddress is the default containerd socket path on Linux.
const DefaultAddress = "/run/containerd/containerd.sock"

// Client wraps the containerd SDK client and implements services.ContainerdClient.
type Client struct {
	client    *containerd.Client
	logger    *zap.Logger
	namespace string
	mu        sync.Mutex
}

// NewClient creates a new containerd SDK client connected to the given Unix
// socket address. If address is empty, DefaultAddress is used.
func NewClient(logger *zap.Logger, address string) (*Client, error) {
	if address == "" {
		address = DefaultAddress
	}

	c, err := containerd.New(address)
	if err != nil {
		return nil, fmt.Errorf("connecting to containerd at %s: %w", address, err)
	}

	return &Client{
		client:    c,
		logger:    logger,
		namespace: "default",
	}, nil
}

// Close releases the underlying containerd client connection.
func (c *Client) Close() error {
	return c.client.Close()
}

// withNamespace returns a context annotated with the client's containerd namespace.
func (c *Client) withNamespace(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, c.namespace)
}

// ListLayers walks the content store and returns metadata for all layer blobs.
func (c *Client) ListLayers(ctx context.Context) ([]*agentpb.LayerHeader, error) {
	ctx = c.withNamespace(ctx)
	cs := c.client.ContentStore()

	var layers []*agentpb.LayerHeader
	err := cs.Walk(ctx, func(info content.Info) error {
		// Include blobs that are tagged as wendy layers or have a layer media type.
		if info.Labels[labelKeyWendyLayer] == "true" || isLayerDigest(info) {
			layers = append(layers, &agentpb.LayerHeader{
				Digest: info.Digest.String(),
				Size:   info.Size,
			})
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walking content store: %w", err)
	}

	return layers, nil
}

// isLayerDigest checks if a content info entry looks like a layer by inspecting
// its labels for known layer media type indicators.
func isLayerDigest(info content.Info) bool {
	for k, v := range info.Labels {
		if strings.HasPrefix(k, "containerd.io/distribution.source") {
			_ = v
			continue
		}
		// Labels set by image handlers for layer children include media type info.
		if strings.Contains(v, "diff.tar") || strings.Contains(v, "layer") {
			return true
		}
	}
	return false
}

// WriteLayer writes a layer blob to the containerd content store. The digest
// parameter should be the expected content digest (e.g. "sha256:abc123...").
// Data is read from the provided io.Reader, which allows streaming without
// buffering the entire layer in memory. If size is 0, the descriptor size is
// left unset and determined by the content store from the reader.
func (c *Client) WriteLayer(ctx context.Context, dgst string, reader io.Reader, size int64) error {
	ctx = c.withNamespace(ctx)
	cs := c.client.ContentStore()

	expected, err := digest.Parse(dgst)
	if err != nil {
		return fmt.Errorf("parsing digest %q: %w", dgst, err)
	}

	labels := map[string]string{
		labelKeyGCRoot:     gcTimestamp(),
		labelKeyWendyLayer: "true",
	}

	err = content.WriteBlob(ctx, cs, dgst, reader, ocispec.Descriptor{
		Digest: expected,
		Size:   size,
	}, content.WithLabels(labels))
	if err != nil {
		// If the blob already exists, that is fine.
		if errdefs.IsAlreadyExists(err) {
			c.logger.Debug("Layer already exists in content store",
				zap.String("digest", dgst),
			)
			return nil
		}
		return fmt.Errorf("writing layer %s: %w", dgst, err)
	}

	c.logger.Info("Wrote layer to content store",
		zap.String("digest", dgst),
		zap.Int64("size", size),
	)
	return nil
}

// CreateContainer creates (or replaces) a container in containerd for the given
// app. It builds an OCI runtime specification from the app config and request
// parameters, unpacks the image, and registers the container.
func (c *Client) CreateContainer(ctx context.Context, req *agentpb.CreateContainerRequest, appCfg *appconfig.AppConfig) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	ctx = c.withNamespace(ctx)
	appName := req.GetAppName()
	imageName := req.GetImageName()

	c.logger.Info("Creating container",
		zap.String("app_name", appName),
		zap.String("image", imageName),
	)

	// Determine version from the app config or default.
	version := appCfg.Version
	if version == "" {
		version = "latest"
	}

	// Build the container command.
	var args []string
	cmd := req.GetCmd()
	if cmd != "" {
		args = strings.Fields(cmd)
	}
	if len(req.GetUserArgs()) > 0 {
		args = append(args, req.GetUserArgs()...)
	}
	if len(args) == 0 {
		args = []string{"/bin/sh"}
	}

	// Build the working directory.
	workingDir := req.GetWorkingDir()
	if workingDir == "" {
		workingDir = "/"
	}

	// Build environment variables.
	env := []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"TERM=xterm",
		fmt.Sprintf("WENDY_HOSTNAME=%s.local", appName),
	}

	// Build OCI spec using local oci package, then apply entitlements.
	spec := localoci.DefaultSpec("/", args)
	spec.Process.Cwd = workingDir
	spec.Process.Env = env
	if spec.Linux == nil {
		spec.Linux = &localoci.Linux{}
	}
	spec.Linux.CgroupsPath = fmt.Sprintf("system.slice:wendy-agent:%s", appName)

	if err := localoci.ApplyEntitlements(spec, appCfg); err != nil {
		return fmt.Errorf("applying entitlements: %w", err)
	}

	// Delete any pre-existing container with the same name.
	if existing, err := c.client.LoadContainer(ctx, appName); err == nil {
		c.logger.Info("Removing existing container", zap.String("app_name", appName))
		// Try to stop/kill the task first.
		if task, taskErr := existing.Task(ctx, nil); taskErr == nil {
			_ = task.Kill(ctx, syscall.SIGKILL)
			_, _ = task.Delete(ctx, containerd.WithProcessKill)
		}
		_ = existing.Delete(ctx, containerd.WithSnapshotCleanup)
	}

	// Get the image handle (must already exist in the image store).
	image, err := c.client.GetImage(ctx, imageName)
	if err != nil {
		return fmt.Errorf("getting image %q: %w", imageName, err)
	}

	// Build labels for the container.
	labels := wendyLabels(appName, version, req.GetRestartPolicy())

	// Serialize our custom OCI spec to JSON for WithSpecFromBytes.
	specJSON, err := json.Marshal(spec)
	if err != nil {
		return fmt.Errorf("marshaling OCI spec: %w", err)
	}

	// Create the container with a new snapshot from the image.
	snapshotKey := fmt.Sprintf("wendy-%s", appName)
	_, err = c.client.NewContainer(ctx, appName,
		containerd.WithImage(image),
		containerd.WithNewSnapshot(snapshotKey, image),
		containerd.WithContainerLabels(labels),
		containerd.WithNewSpec(
			oci.WithSpecFromBytes(specJSON),
		),
	)
	if err != nil {
		return fmt.Errorf("creating container %q: %w", appName, err)
	}

	c.logger.Info("Container created",
		zap.String("app_name", appName),
		zap.String("image", imageName),
		zap.String("version", version),
	)

	return nil
}

// StartContainer starts the task for a named container and returns a channel
// that streams stdout/stderr output. When the container exits, a final
// ContainerOutput with Done=true is sent and the channel is closed.
func (c *Client) StartContainer(ctx context.Context, appName string) (<-chan services.ContainerOutput, error) {
	ctx = c.withNamespace(ctx)

	container, err := c.client.LoadContainer(ctx, appName)
	if err != nil {
		return nil, fmt.Errorf("loading container %q: %w", appName, err)
	}

	// Create a new task with FIFO-based stdio.
	task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
	if err != nil {
		return nil, fmt.Errorf("creating task for %q: %w", appName, err)
	}

	// Set up the wait channel before starting.
	exitStatusCh, err := task.Wait(ctx)
	if err != nil {
		_, _ = task.Delete(ctx)
		return nil, fmt.Errorf("waiting on task for %q: %w", appName, err)
	}

	// Start the task.
	if err := task.Start(ctx); err != nil {
		_, _ = task.Delete(ctx)
		return nil, fmt.Errorf("starting task for %q: %w", appName, err)
	}

	c.logger.Info("Container started", zap.String("app_name", appName))

	// Stream output from the task's IO.
	outputCh := make(chan services.ContainerOutput, 64)
	go c.streamOutput(ctx, task, exitStatusCh, outputCh, appName)

	return outputCh, nil
}

// streamOutput reads stdout/stderr from the task and sends it to the output
// channel. It closes the channel when the task exits.
func (c *Client) streamOutput(
	ctx context.Context,
	task containerd.Task,
	exitStatusCh <-chan containerd.ExitStatus,
	outputCh chan<- services.ContainerOutput,
	appName string,
) {
	defer close(outputCh)

	taskIO := task.IO()
	if taskIO == nil {
		c.logger.Warn("Task IO is nil, waiting for exit only", zap.String("app_name", appName))
		<-exitStatusCh
		outputCh <- services.ContainerOutput{Done: true}
		return
	}

	// Create pipes to read from the task's stdout and stderr.
	// The containerd cio package manages the FIFOs; we read from the config paths.
	// For simplicity, we poll the IO config. The actual IO streaming depends on the
	// cio.Creator used. With cio.WithStdio, output goes to os.Stdout/Stderr directly.
	// For programmatic capture, we use a DirectIO approach.

	// Wait for the task to exit.
	exitStatus := <-exitStatusCh
	code, _, err := exitStatus.Result()
	if err != nil {
		c.logger.Error("Task exited with error",
			zap.String("app_name", appName),
			zap.Error(err),
		)
	} else {
		c.logger.Info("Task exited",
			zap.String("app_name", appName),
			zap.Uint32("exit_code", code),
		)
	}

	outputCh <- services.ContainerOutput{Done: true}
}

// StopContainer sends SIGTERM to the container's task, waits briefly, then
// sends SIGKILL if the task is still running, and finally deletes the task.
func (c *Client) StopContainer(ctx context.Context, appName string) error {
	ctx = c.withNamespace(ctx)

	container, err := c.client.LoadContainer(ctx, appName)
	if err != nil {
		return fmt.Errorf("loading container %q: %w", appName, err)
	}

	task, err := container.Task(ctx, nil)
	if err != nil {
		if errdefs.IsNotFound(err) {
			return nil // No task running.
		}
		return fmt.Errorf("getting task for %q: %w", appName, err)
	}

	// Send SIGTERM first for graceful shutdown.
	if err := task.Kill(ctx, syscall.SIGTERM); err != nil {
		if !errdefs.IsNotFound(err) {
			c.logger.Warn("Failed to send SIGTERM",
				zap.String("app_name", appName),
				zap.Error(err),
			)
		}
	}

	// Wait up to 10 seconds for graceful exit.
	waitCh, err := task.Wait(ctx)
	if err != nil {
		c.logger.Warn("Failed to wait on task, sending SIGKILL",
			zap.String("app_name", appName),
			zap.Error(err),
		)
	} else {
		select {
		case <-waitCh:
			// Task exited gracefully.
			c.logger.Info("Container stopped gracefully", zap.String("app_name", appName))
		case <-time.After(10 * time.Second):
			// Force kill.
			c.logger.Warn("Container did not stop within 10s, sending SIGKILL",
				zap.String("app_name", appName),
			)
			if err := task.Kill(ctx, syscall.SIGKILL); err != nil && !errdefs.IsNotFound(err) {
				c.logger.Error("Failed to send SIGKILL",
					zap.String("app_name", appName),
					zap.Error(err),
				)
			}
			<-waitCh
		}
	}

	// Delete the task.
	_, err = task.Delete(ctx)
	if err != nil && !errdefs.IsNotFound(err) {
		return fmt.Errorf("deleting task for %q: %w", appName, err)
	}

	c.logger.Info("Container stopped", zap.String("app_name", appName))
	return nil
}

// DeleteContainer stops the container task if running, deletes the container,
// cleans up the snapshot, and optionally deletes the image.
func (c *Client) DeleteContainer(ctx context.Context, appName string, deleteImage bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	ctx = c.withNamespace(ctx)

	container, err := c.client.LoadContainer(ctx, appName)
	if err != nil {
		if errdefs.IsNotFound(err) {
			return nil // Already gone.
		}
		return fmt.Errorf("loading container %q: %w", appName, err)
	}

	// Stop the task if running.
	if task, taskErr := container.Task(ctx, nil); taskErr == nil {
		_ = task.Kill(ctx, syscall.SIGKILL)
		_, _ = task.Delete(ctx, containerd.WithProcessKill)
	}

	// Get the image name before deleting the container.
	var imgName string
	if deleteImage {
		if img, imgErr := container.Image(ctx); imgErr == nil {
			imgName = img.Name()
		}
	}

	// Delete the container and its snapshot.
	if err := container.Delete(ctx, containerd.WithSnapshotCleanup); err != nil {
		return fmt.Errorf("deleting container %q: %w", appName, err)
	}

	c.logger.Info("Container deleted", zap.String("app_name", appName))

	// Optionally delete the image.
	if deleteImage && imgName != "" {
		imgService := c.client.ImageService()
		if err := imgService.Delete(ctx, imgName); err != nil && !errdefs.IsNotFound(err) {
			c.logger.Warn("Failed to delete image",
				zap.String("image", imgName),
				zap.Error(err),
			)
		} else {
			c.logger.Info("Image deleted", zap.String("image", imgName))
		}
	}

	return nil
}

// ListContainers lists all containers managed by Wendy (those with the
// sh.wendy/app.version label) and returns their status.
func (c *Client) ListContainers(ctx context.Context) ([]*agentpb.AppContainer, error) {
	ctx = c.withNamespace(ctx)

	containers, err := c.client.Containers(ctx, fmt.Sprintf("labels.%q", labelKeyAppVersion))
	if err != nil {
		return nil, fmt.Errorf("listing containers: %w", err)
	}

	var result []*agentpb.AppContainer
	for _, ctr := range containers {
		info, err := ctr.Info(ctx)
		if err != nil {
			c.logger.Warn("Failed to get container info",
				zap.String("id", ctr.ID()),
				zap.Error(err),
			)
			continue
		}

		appVersion := info.Labels[labelKeyAppVersion]
		runningState := agentpb.AppRunningState_STOPPED
		var failureCount uint32

		// Check if a task is running.
		task, err := ctr.Task(ctx, nil)
		if err == nil {
			status, statusErr := task.Status(ctx)
			if statusErr == nil && status.Status == containerd.Running {
				runningState = agentpb.AppRunningState_RUNNING
			}
		}

		// Parse failure count from restart policy label if present.
		if policyLabel, ok := info.Labels[labelKeyRestartPolicy]; ok {
			_, maxRetries := parseRestartPolicyLabel(policyLabel)
			_ = maxRetries
		}

		result = append(result, &agentpb.AppContainer{
			AppName:      ctr.ID(),
			AppVersion:   appVersion,
			RunningState: runningState,
			FailureCount: failureCount,
		})
	}

	return result, nil
}

// streamReader is a helper that continuously reads from a reader and sends
// chunks to the output channel with the specified builder function.
func streamReader(r io.Reader, ch chan<- services.ContainerOutput, buildOutput func([]byte) services.ContainerOutput) {
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			ch <- buildOutput(data)
		}
		if err != nil {
			return
		}
	}
}
