package containerd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"

	"go.uber.org/zap"

	"github.com/wendylabsinc/wendy/go/internal/shared/appconfig"
)

const (
	cniPluginDir = "/opt/cni/bin"
	cniStateDir  = "/run/wendy/cni"
)

// cniResult is a minimal subset of the CNI ADD result.
type cniResult struct {
	IPs []struct {
		Address string `json:"address"` // CIDR notation, e.g. "10.x.y.z/28"
	} `json:"ips"`
}

// netnsPathPattern accepts the two netns path forms used in this package:
//   - /proc/{pid}/ns/net  — direct procfs reference
//   - /proc/self/fd/{n}   — fd-anchored reference (prevents PID-reuse races)
var netnsPathPattern = regexp.MustCompile(`^(/proc/\d+/ns/net|/proc/self/fd/\d+)$`)

// containerIDPattern is an allowlist for CNI containerID values. Wendy
// container IDs are either a bare appID or "{appID}@{serviceName}", so valid
// characters are letters, digits, dot, underscore, hyphen, and '@'.
// This allowlist replaces a previous denylist that blocked only a few
// characters; an allowlist is more robust against unforeseen CNI plugin
// behaviour (SOC2-CC6, ISO27001-A.8, NIST-SI-10).
var containerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._@-]{0,319}$`)

// allocateSubnet deterministically maps an appID to a /28 subnet within
// 10.0.0.0/8 using three bytes of a SHA-256 digest (~1M possible subnets).
// Birthday-paradox collision probability: ~0.05% at 30 apps, ~0.5% at 100.
// The SHA-256 digest ensures uniform distribution; it does not provide
// resistance against a caller who can iterate appIDs to find a collision
// (SOC2-CC6, ISO27001-A.8, NIST-SC-7).
func allocateSubnet(appID string) string {
	h := sha256.Sum256([]byte(appID))
	// Use three bytes from the digest: second octet, third octet, /28 boundary.
	b2 := h[0]
	b3 := h[1]
	b4 := (h[2] & 0xf) << 4 // /28 boundary: 0, 16, 32, …, 240
	return fmt.Sprintf("10.%d.%d.%d/28", b2, b3, b4)
}

// bridgeName returns a Linux network interface name for the app's CNI bridge.
// The kernel limit is 15 chars (IFNAMSIZ-1). Short appIDs that fit are embedded
// directly; longer ones fall back to an 8-hex-digit SHA-256 prefix for uniform
// distribution (birthday collision probability ~0.12% at 100 apps).
func bridgeName(appID string) string {
	const prefix = "wendy-br-"
	if len(prefix)+len(appID) <= 15 {
		return prefix + appID
	}
	h := sha256.Sum256([]byte(appID))
	return fmt.Sprintf("wendy-%08x", binary.BigEndian.Uint32(h[:4]))
}

// validateCNIInputs provides defence-in-depth validation of the values that
// reach the CNI exec environment, guarding against any future caller that
// bypasses the RPC-layer ValidateAppID check (SOC2-CC6, NIST-SI-10).
func validateCNIInputs(appID, containerID, netnsPath string) error {
	if err := appconfig.ValidateAppID(appID); err != nil {
		return fmt.Errorf("CNI: %w", err)
	}
	if !containerIDPattern.MatchString(containerID) {
		return fmt.Errorf("CNI: containerID %q does not match allowed pattern (letters, digits, '.', '_', '@', '-'; 1–320 chars)", containerID)
	}
	if !netnsPathPattern.MatchString(netnsPath) {
		return fmt.Errorf("CNI: netnsPath %q does not match expected pattern", netnsPath)
	}
	return nil
}

// buildBridgeCNIConfig returns the JSON config string for the CNI bridge plugin.
func buildBridgeCNIConfig(appID, subnet string) string {
	cfg := map[string]interface{}{
		"cniVersion": "0.4.0",
		"name":       "wendy-" + appID,
		"type":       "bridge",
		"bridge":     bridgeName(appID), // capped at 15 chars (IFNAMSIZ-1)
		"isGateway":  true,
		"ipMasq":     true,
		"ipam": map[string]interface{}{
			"type":    "host-local",
			"subnet":  subnet,
			"dataDir": cniStateDir + "/" + appID,
		},
	}
	b, _ := json.Marshal(cfg)
	return string(b)
}

// cniStdoutLimit is the maximum bytes read from the CNI plugin's stdout.
// A valid CNI ADD response is well under 1 KB; this cap prevents memory
// exhaustion if the binary at cniPluginDir is replaced or emits junk
// (SOC2-CC6, NIST-SI-10: input bounds enforcement).
const cniStdoutLimit = 64 << 10 // 64 KB

// CNIAdd calls the CNI bridge plugin ADD for a container, returning its
// assigned IP address. netnsPath is the container's network namespace path
// (e.g. /proc/self/fd/{n} for fd-anchored references, or /proc/{pid}/ns/net).
func (c *Client) CNIAdd(ctx context.Context, appID, containerID, netnsPath string) (string, error) {
	if err := validateCNIInputs(appID, containerID, netnsPath); err != nil {
		return "", err
	}
	subnet := allocateSubnet(appID)
	cfgJSON := buildBridgeCNIConfig(appID, subnet)

	cmd := exec.CommandContext(ctx, cniPluginDir+"/bridge")
	cmd.Stdin = strings.NewReader(cfgJSON)
	cmd.Env = []string{
		"CNI_COMMAND=ADD",
		"CNI_CONTAINERID=" + containerID,
		"CNI_NETNS=" + netnsPath,
		"CNI_IFNAME=eth0",
		"CNI_PATH=" + cniPluginDir,
	}
	// Bound stdout to cniStdoutLimit to guard against a rogue or replaced
	// binary emitting unbounded data that would exhaust agent memory.
	var stdoutBuf, stderr bytes.Buffer
	cmd.Stdout = &limitedWriter{w: &stdoutBuf, remaining: cniStdoutLimit}
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		c.logger.Warn("CNI ADD failed",
			zap.String("app_id", appID),
			zap.String("container_id", containerID),
			zap.String("stderr", stderr.String()),
			zap.Error(err))
		return "", fmt.Errorf("CNI ADD failed for %s/%s; see agent logs for details", appID, containerID)
	}

	var result cniResult
	if err := json.Unmarshal(stdoutBuf.Bytes(), &result); err != nil {
		return "", fmt.Errorf("parsing CNI ADD result for %s/%s: %w", appID, containerID, err)
	}
	if len(result.IPs) == 0 {
		return "", fmt.Errorf("CNI ADD returned no IPs for %s/%s", appID, containerID)
	}
	rawIP, _, _ := strings.Cut(result.IPs[0].Address, "/")
	// Validate and normalise the IP before using it in /etc/hosts bind-mounts.
	// An unvalidated string from CNI stdout could contain newlines or tabs that
	// poison the hosts file injected into sibling containers (SOC2-CC6, NIST-SC-7).
	parsed := net.ParseIP(rawIP)
	if parsed == nil {
		return "", fmt.Errorf("CNI ADD returned invalid IP %q for %s/%s", rawIP, appID, containerID)
	}
	ip := parsed.String()
	c.logger.Info("CNI ADD: assigned IP",
		zap.String("app_id", appID),
		zap.String("container_id", containerID),
		zap.String("ip", ip))
	return ip, nil
}

// limitedWriter is an io.Writer that accepts at most `remaining` bytes,
// silently discarding any excess. Prevents unbounded buffer growth when
// piping output from an external binary (SOC2-CC6, NIST-SI-10).
type limitedWriter struct {
	w         io.Writer
	remaining int
}

func (lw *limitedWriter) Write(p []byte) (int, error) {
	if lw.remaining <= 0 {
		return len(p), nil // discard
	}
	if len(p) > lw.remaining {
		p = p[:lw.remaining]
	}
	n, err := lw.w.Write(p)
	lw.remaining -= n
	return n, err
}

// writeHostsFile writes a hosts-format file at path with entries for each
// service name → IP mapping. Always includes 127.0.0.1 localhost.
// Entries are written in sorted order for determinism.
func writeHostsFile(path string, serviceIPs map[string]string) error {
	var sb strings.Builder
	sb.WriteString("127.0.0.1\tlocalhost\n")
	names := make([]string, 0, len(serviceIPs))
	for n := range serviceIPs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintf(&sb, "%s\t%s\n", serviceIPs[name], name)
	}
	return os.WriteFile(path, []byte(sb.String()), 0o644)
}

// CNIDel calls the CNI bridge plugin DEL to release a container's IP.
// Errors are logged as warnings but not returned — DEL is best-effort.
func (c *Client) CNIDel(ctx context.Context, appID, containerID, netnsPath string) error {
	if err := validateCNIInputs(appID, containerID, netnsPath); err != nil {
		c.logger.Warn("CNI DEL skipped: invalid inputs", zap.Error(err))
		return nil
	}
	subnet := allocateSubnet(appID)
	cfgJSON := buildBridgeCNIConfig(appID, subnet)

	cmd := exec.CommandContext(ctx, cniPluginDir+"/bridge")
	cmd.Stdin = strings.NewReader(cfgJSON)
	cmd.Env = []string{
		"CNI_COMMAND=DEL",
		"CNI_CONTAINERID=" + containerID,
		"CNI_NETNS=" + netnsPath,
		"CNI_IFNAME=eth0",
		"CNI_PATH=" + cniPluginDir,
	}
	if err := cmd.Run(); err != nil {
		c.logger.Warn("CNI DEL failed (non-fatal)",
			zap.String("app_id", appID),
			zap.String("container_id", containerID),
			zap.Error(err))
	}
	return nil
}
