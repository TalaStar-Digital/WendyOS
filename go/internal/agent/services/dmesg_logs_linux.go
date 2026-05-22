//go:build linux

package services

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"go.uber.org/zap"
	"golang.org/x/sys/unix"

	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

const (
	// dmesgMaxMsgsPerSec caps non-critical messages forwarded per second.
	// KERN_EMERG/ALERT/CRIT messages are always forwarded regardless of this limit.
	dmesgMaxMsgsPerSec = 500

	// dmesgMaxMessageLen caps the byte length of a single kernel message body.
	dmesgMaxMessageLen = 4096

	// minValidTimestampNs rejects computed timestamps earlier than year 2000.
	minValidTimestampNs = 946684800 * int64(time.Second)

	// maxFutureSkewNs rejects timestamps more than 24 h in the future.
	maxFutureSkewNs = int64(24 * time.Hour)

	// maxReasonableTsUS rejects kernel timestamps beyond 100 years of uptime,
	// guarding against integer overflow in the tsUS*1000 multiplication.
	maxReasonableTsUS = int64(100 * 365 * 24 * 3600 * 1e6) // 100 years in µs

	// dmesgPIIAllowFile must exist on-disk to enable WENDY_DMESG_REDACT=false.
	// Requires filesystem write access separate from env-var permission domain.
	dmesgPIIAllowFile = "/etc/wendy/dmesg-pii-allowed"

	// dmesgPIIRecheckInterval controls how often the PII allow-file is re-validated.
	// If the file is removed after startup, redaction is re-enabled within this interval
	// so a momentary file creation cannot permanently disable redaction for the process
	// lifetime (TOCTOU mitigation).
	dmesgPIIRecheckInterval = 60 * time.Second
)

// piiPatterns matches host-identifying values in kernel messages for redaction.
// Covers: MAC (colon/hyphen), IPv4, USB serial numbers, OOM process names+PIDs,
// filesystem home paths, kernel comm= annotations, Bluetooth bdaddr values,
// network interface names, and block device node paths.
var piiPatterns = regexp.MustCompile(
	`(?i)(?:` +
		// MAC address (colon separated, exactly 6 octets)
		`(?:[0-9a-f]{2}:){5}[0-9a-f]{2}` +
		// MAC address (hyphen separated, exactly 6 octets)
		`|(?:[0-9a-f]{2}-){5}[0-9a-f]{2}` +
		// IPv4 address
		`|\b(?:\d{1,3}\.){3}\d{1,3}\b` +
		// USB serial number variants (e.g. "SerialNumber: ABC123DEF", "ID_SERIAL=XYZ")
		`|SerialNumber:\s+\S+` +
		`|ID_SERIAL(?:_SHORT)?=\S+` +
		// OOM killer: process name+PID (e.g. "Kill process 1234 (nginx)")
		`|Kill(?:ed)?\s+process\s+\d+\s+\([^)]+\)` +
		// Filesystem paths containing usernames
		`|/(?:home|Users|root)/[^\s/]+` +
		// Kernel process name annotations (e.g. "comm=nginx")
		`|comm=\S+` +
		// Audit-log argument values (e.g. a0="bash" a1="-c" a2="/tmp/secret-token")
		`|a\d+="[^"]*"` +
		// OOM/audit argv arrays (e.g. argv[0]=/usr/bin/nginx)
		`|argv\[\d+\]=[^\s,]+` +
		// Bluetooth device address (e.g. "bdaddr 00:11:22:33:44:55")
		`|bdaddr\s+(?:[0-9a-f]{2}:){5}[0-9a-f]{2}` +
		// Network interface names (e.g. "eth0", "wlan0", "enp3s0", "docker0").
		// These are hardware-identifying and appear in kernel network messages.
		`|\b(?:eth|wlan|ens|enp|wlp|docker|veth|br-|virbr)\w+\b` +
		// Block device node paths (e.g. "/dev/sda", "/dev/nvme0n1", "/dev/mmcblk0").
		// These are hardware-identifying and appear in storage/filesystem messages.
		`|/dev/(?:sd[a-z]\w*|nvme\w+|mmcblk\w+|vd[a-z]\w*)` +
		`)`,
)

// piiIPv6Pattern matches IPv6-style addresses (≥2 colon-terminated hex groups of
// 1–4 chars). Requires non-empty groups ({1,4}) to avoid over-matching version
// strings, kernel load addresses, and other colon-separated hex values.
// Abbreviated forms with leading :: (e.g. ::1, fe80::1) are not matched by this
// pattern; full-form addresses (2001:db8:...) are covered.
// Kept separate from piiPatterns and gated behind strings.ContainsRune(':').
var piiIPv6Pattern = regexp.MustCompile(`(?i)(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}`)

// piiKernelPtrPattern matches kernel pointer addresses (e.g. "0xffffffff81234567").
// Kept separate and gated behind strings.Contains("0x") to avoid scanning messages
// that cannot contain a pointer, reducing per-message cost at high message rates.
var piiKernelPtrPattern = regexp.MustCompile(`(?i)0x[0-9a-f]{8,16}`)

// csiRemnantPattern strips orphaned ANSI/VT escape remnants left after ESC
// (U+001B, removed by strings.Map's r < 0x20 check) is stripped:
//   - Standard CSI: "[" + decimal/semicolon params + letter (e.g. "[31m")
//   - Private/intermediate CSI: "[" + "?", "!", "<", ">", "=" + params + letter
//     (e.g. "[?25l" cursor visibility, "[>c" device attributes)
//   - OSC remnants: "]" + numeric param + ";" + text, terminator already removed
//     by the control-char strip above (BEL=0x07, ST=0x9c are both <0x20 or C1)
var csiRemnantPattern = regexp.MustCompile(`\[[0-9;?!<>=]*[A-Za-z]|\]\d+;[^\x00-\x1f]*`)

// CollectDmesgLogs reads kernel messages from /dev/kmsg and publishes them as
// OTel log records at debug/trace severity. It replays buffered kernel messages
// first, then follows new ones. Blocks until ctx is cancelled.
//
// Requires /etc/wendy/dmesg-dpia-confirmed with non-empty content (DPIA record).
// PII redaction is enabled by default. To disable, set WENDY_DMESG_REDACT=false
// AND create /etc/wendy/dmesg-pii-allowed on the host filesystem.
//
// NOTE: All kernel severity levels are intentionally mapped into the OTel
// debug/trace band. KERN_EMERG/ALERT/CRIT additionally emit a zap.Warn so
// they are visible in the agent's own log stream. See kernelLevelToOTEL.
func CollectDmesgLogs(ctx context.Context, logger *zap.Logger, broadcaster *TelemetryBroadcaster) {
	// Require a file-based DPIA confirmation. Unlike an env var, a file:
	//   - Cannot be satisfied by copying an env block in a container spec
	//   - Produces a filesystem access log entry (audit trail)
	//   - Content is logged below for non-repudiation
	dpiaContent, readErr := os.ReadFile(DmesgDPIAConfirmFile)
	if readErr != nil || len(strings.TrimSpace(string(dpiaContent))) == 0 {
		logger.Error("kernel dmesg collection requires "+DmesgDPIAConfirmFile+" with non-empty content",
			zap.String("reason", "GDPR Art.35 requires a documented DPIA before forwarding kernel messages to an external backend"),
		)
		return
	}
	// Log hash + length, not content: the file may contain operator names,
	// email addresses, ticket numbers, or other PII. The hash provides
	// non-repudiation without exposing the content to log sinks.
	h := sha256.Sum256(dpiaContent)
	// confirmation_len is intentionally omitted: byte-length is metadata that
	// could narrow dictionary attacks against the confirmation text.
	// The SHA-256 hash alone is sufficient for non-repudiation.
	logger.Info("dmesg DPIA confirmation found",
		zap.String("file", DmesgDPIAConfirmFile),
		zap.String("confirmation_sha256", hex.EncodeToString(h[:])),
		// Best-effort caveat in the non-repudiation record so the limitation
		// is visible alongside the DPIA acknowledgement rather than only in a
		// later startup-warning log line that an operator might overlook.
		zap.String("pii_redact_scope", "best-effort"),
		zap.Strings("pii_redact_gaps", []string{
			"NFS-paths", "unlabelled-kernel-fields",
			"hostname-FQDN-variants", "hostname-mDNS-aliases",
			"kernel-audit-uid-gid-pid", "wifi-ssid",
			"usb-product-strings", "oom-cmdline", "custom-kernel-module-output",
		}),
	)

	// redactAtomic: 1 = redact enabled (safe default), 0 = redact disabled.
	// Using an atomic int32 allows the periodic re-check goroutine below to
	// re-enable redaction if the allow-file disappears after startup, so a
	// momentary file creation cannot permanently disable redaction.
	//
	// Disabling requires BOTH WENDY_DMESG_REDACT=false (env-var domain) AND
	// the existence of dmesgPIIAllowFile (filesystem domain). Separate permission
	// domains: an actor who can only set env vars cannot bypass redaction.
	var redactAtomic int32 = 1
	if v, err := strconv.ParseBool(os.Getenv("WENDY_DMESG_REDACT")); err == nil && !v {
		if _, statErr := os.Stat(dmesgPIIAllowFile); statErr == nil {
			atomic.StoreInt32(&redactAtomic, 0)
		} else {
			logger.Warn("WENDY_DMESG_REDACT=false requires "+dmesgPIIAllowFile+" to exist; keeping redaction enabled",
				zap.String("reason", "file-based out-of-band confirmation required; env-var alone is insufficient"),
			)
		}
	}

	// Capture hostname once at startup for both redact paths:
	// - redact=true: used for per-message literal hostname substitution.
	// - redact=false: included in the OTel resource as service.instance.id.
	// Note: only the exact os.Hostname() string is redacted; FQDN variants,
	// mDNS (.local) names, and hostname aliases are not covered and are
	// listed in redact_not_covered at startup. The hostname is a process
	// constant already present in kernel memory — caching it here adds no
	// additional retention risk vs. fetching it per-message.
	hostname, _ := os.Hostname()

	f, err := os.Open("/dev/kmsg")
	if err != nil {
		logger.Warn("dmesg collection unavailable", zap.Error(err))
		return
	}

	// Verify /dev/kmsg is actually a character device to guard against a
	// container bind-mount replacing it with a regular file or FIFO.
	info, statErr := f.Stat()
	if statErr != nil || info.Mode()&os.ModeCharDevice == 0 {
		logger.Warn("dmesg: /dev/kmsg is not a character device; skipping collection",
			zap.String("mode", func() string {
				if statErr != nil {
					return statErr.Error()
				}
				return info.Mode().String()
			}()))
		_ = f.Close()
		return
	}

	// Verify device major/minor numbers match /dev/kmsg (major=1, minor=11) to
	// prevent a bind-mount substituting another char device (e.g. /dev/urandom).
	var kst unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &kst); err == nil {
		if maj, min := unix.Major(kst.Rdev), unix.Minor(kst.Rdev); maj != 1 || min != 11 {
			logger.Warn("dmesg: /dev/kmsg has unexpected device numbers; skipping",
				zap.Uint32("major", maj),
				zap.Uint32("minor", min),
			)
			_ = f.Close()
			return
		}
	}

	if atomic.LoadInt32(&redactAtomic) != 0 {
		// Warn explicitly about best-effort scope so the gaps are visible in the
		// audit log regardless of downstream monitoring thresholds.
		logger.Warn("kernel dmesg collection started; PII redaction is best-effort only",
			zap.String("source", "/dev/kmsg"),
			zap.Bool("redact", true),
			zap.Strings("redact_covered", []string{
				"MAC-address", "IPv4-address", "IPv6-address", "USB-SerialNumber", "ID_SERIAL",
				"Bluetooth-bdaddr", "OOM-process-name+PID", "filesystem-home-paths",
				"comm=", "process-argv", "kernel-pointer-addresses", "network-interface-names",
				"block-device-paths", "hostname",
			}),
			zap.Strings("redact_not_covered", []string{
				"NFS-paths", "unlabelled-kernel-fields",
				"hostname-FQDN-variants", "hostname-mDNS-aliases",
				"kernel-audit-uid-gid-pid", "wifi-ssid",
				"usb-product-strings", "oom-cmdline", "custom-kernel-module-output",
			}),
			zap.String("dpia_file", DmesgDPIAConfirmFile),
		)
	} else {
		logger.Warn("kernel dmesg collection started with PII redaction DISABLED",
			zap.String("source", "/dev/kmsg"),
			zap.Bool("redact", false),
			zap.String("compliance_note", "raw kernel messages forwarded; GDPR/compliance obligations are operator responsibility"),
		)
	}
	defer logger.Info("kernel dmesg collection stopped")

	// sync.Once ensures only one close fires even though both the ctx-cancel
	// goroutine and the defer call closeFile().
	var closeOnce sync.Once
	closeFile := func() { closeOnce.Do(func() { _ = f.Close() }) }
	go func() {
		<-ctx.Done()
		closeFile()
	}()
	defer closeFile()

	// Periodically re-validate the PII allow-file. If it disappears after startup,
	// re-enable redaction so that a momentary file creation does not permanently
	// disable redaction for the process lifetime (TOCTOU mitigation).
	if atomic.LoadInt32(&redactAtomic) == 0 {
		go func() {
			ticker := time.NewTicker(dmesgPIIRecheckInterval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if _, statErr := os.Stat(dmesgPIIAllowFile); statErr != nil {
						atomic.StoreInt32(&redactAtomic, 1)
						logger.Warn("dmesg: PII allow-file removed; redaction re-enabled",
							zap.String("file", dmesgPIIAllowFile),
						)
					}
				}
			}
		}()
	}

	// Periodically re-validate the DPIA confirmation file. If it is removed
	// after startup, stop collection so a revoked DPIA takes effect within one
	// recheck interval (TOCTOU mitigation).
	go func() {
		ticker := time.NewTicker(dmesgPIIRecheckInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, statErr := os.Stat(DmesgDPIAConfirmFile); statErr != nil {
					logger.Warn("dmesg: DPIA confirmation file removed; stopping kernel log collection",
						zap.String("file", DmesgDPIAConfirmFile),
					)
					closeFile()
					return
				}
			}
		}
	}()

	resource := dmesgResource(atomic.LoadInt32(&redactAtomic) != 0, hostname)
	bootEpoch := kmsgBootEpochNanoseconds()

	// Sliding-window rate limiter for non-critical messages only.
	// KERN_EMERG (0), KERN_ALERT (1), KERN_CRIT (2) bypass this entirely.
	// All three window variables are accessed exclusively from the scanner
	// goroutine below — there is no concurrent access and no mutex is needed.
	var (
		windowStart = time.Now()
		windowCount int
		windowDrop  int
	)
	rateAllow := func() bool {
		now := time.Now()
		if now.Sub(windowStart) >= time.Second {
			if windowDrop > 0 {
				logger.Warn("dmesg rate limit: messages dropped in last second",
					zap.Int("dropped", windowDrop),
					zap.Int("forwarded", windowCount),
				)
			}
			windowStart = now
			windowCount = 0
			windowDrop = 0
		}
		if windowCount >= dmesgMaxMsgsPerSec {
			windowDrop++
			return false
		}
		windowCount++
		return true
	}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 8192), 256*1024)
	for {
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				if errors.Is(err, bufio.ErrTooLong) {
					// A single oversized kmsg line must not terminate collection.
					// Recreating the scanner on the same fd is safe: /dev/kmsg
					// advances the read position per-record at the kernel level,
					// so the next Read() starts at the following message.
					logger.Warn("dmesg: oversized kernel message dropped; restarting scanner")
					scanner = bufio.NewScanner(f)
					scanner.Buffer(make([]byte, 0, 8192), 256*1024)
					continue
				}
				if !errors.Is(err, os.ErrClosed) {
					logger.Warn("dmesg scanner exited with error", zap.Error(err))
				}
			}
			break
		}
		line := scanner.Text()
		if len(line) == 0 || line[0] == ' ' {
			continue
		}

		level, message, tsUS, ok := parseKmsgLine(line)
		if !ok {
			continue
		}
		if len(message) > dmesgMaxMessageLen {
			message = message[:dmesgMaxMessageLen]
		}
		if atomic.LoadInt32(&redactAtomic) != 0 {
			// Capture original text for gate checks BEFORE piiPatterns runs.
			// After piiPatterns replaces values with "<redacted>", the resulting
			// colons and "0x" substrings inside those tokens must not be used as
			// gates — doing so causes the IPv6/pointer patterns to run against
			// already-redacted text, missing content that appeared in the original.
			rawMessage := message
			message = piiPatterns.ReplaceAllString(message, "<redacted>")
			// IPv6 and kernel-pointer patterns run only when the original message
			// contained the necessary prefix, keeping per-message regex cost
			// proportional to the original content rather than scanning artifact
			// colons/hex inserted by earlier <redacted> substitutions.
			if strings.ContainsRune(rawMessage, ':') {
				message = piiIPv6Pattern.ReplaceAllString(message, "<redacted>")
			}
			if strings.Contains(rawMessage, "0x") {
				message = piiKernelPtrPattern.ReplaceAllString(message, "<redacted>")
			}
			// Redact exact hostname literal. Cached at startup; FQDN variants
			// and mDNS names are not covered (see redact_not_covered in the
			// startup warning).
			if hostname != "" {
				message = strings.ReplaceAll(message, hostname, "<redacted>")
			}
		}

		isCritical := level <= 2 // KERN_EMERG, KERN_ALERT, KERN_CRIT

		// Critical messages bypass the rate limiter so they are never silently
		// dropped. The zap.Warn fires after the rate check so the agent log
		// stays visible at the default INFO+ level.
		if !isCritical && !rateAllow() {
			continue
		}
		if isCritical {
			// Log level only — message body is omitted to avoid routing
			// partially-redacted content to a second log sink with potentially
			// different retention/access policies. Full content is in OTel.
			logger.Warn("critical kernel message received",
				zap.Int("kernel_level", level),
			)
		}

		timeNano := kmsgTimestampToWall(tsUS, bootEpoch)
		severity, severityText := kernelLevelToOTEL(level)
		broadcaster.PublishLogs(&otelpb.ExportLogsServiceRequest{
			ResourceLogs: []*otelpb.ResourceLogs{
				{
					Resource: resource,
					ScopeLogs: []*otelpb.ScopeLogs{
						{
							Scope: &otelpb.InstrumentationScope{Name: "wendy.dmesg"},
							LogRecords: []*otelpb.LogRecord{
								{
									TimeUnixNano:         timeNano,
									ObservedTimeUnixNano: uint64(time.Now().UnixNano()),
									SeverityNumber:       severity,
									SeverityText:         severityText,
									Body: &otelpb.AnyValue{
										Value: &otelpb.AnyValue_StringValue{StringValue: message},
									},
								},
							},
						},
					},
				},
			},
		})
	}

	// Flush any drops accumulated in the current window that were never reported
	// because no new message arrived to trigger the window-rollover log line.
	if windowDrop > 0 {
		logger.Warn("dmesg rate limit: messages dropped at shutdown",
			zap.Int("dropped", windowDrop),
			zap.Int("forwarded", windowCount),
		)
	}
}

// dmesgResource returns the OTel resource for kernel log records.
// service.instance.id (hostname) is gated behind redact=false so the device
// hostname is not forwarded when PII redaction is enabled. The wendy.dmesg.redact
// attribute records the effective redaction state for downstream monitoring.
func dmesgResource(redact bool, hostname string) *otelpb.Resource {
	redactStr := "true"
	if !redact {
		redactStr = "false"
	}
	attrs := []*otelpb.KeyValue{
		stringKV("service.name", "kernel"),
		stringKV("service.namespace", "wendy"),
		stringKV("wendy.dmesg.redact", redactStr),
	}
	if !redact && hostname != "" {
		attrs = append(attrs, stringKV("service.instance.id", hostname))
	}
	return &otelpb.Resource{Attributes: attrs}
}

// kmsgBootEpochNanoseconds returns the wall-clock Unix nanosecond timestamp
// corresponding to the kernel boot instant, computed from CLOCK_BOOTTIME.
// Returns 0 if unavailable.
func kmsgBootEpochNanoseconds() int64 {
	var ts unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_BOOTTIME, &ts); err != nil {
		return 0
	}
	bootNowNs := ts.Sec*int64(time.Second) + ts.Nsec
	return time.Now().UnixNano() - bootNowNs
}

// kmsgTimestampToWall converts a kernel timestamp (microseconds since boot) to
// a wall-clock Unix nanosecond value. Falls back to time.Now() if outside a
// plausible range to guard against NTP steps or boot-epoch skew.
func kmsgTimestampToWall(tsUS int64, bootEpoch int64) uint64 {
	now := time.Now().UnixNano()
	// maxReasonableTsUS guard prevents integer overflow in tsUS*1000 for
	// malformed or attacker-supplied timestamps (100-year uptime upper bound).
	if bootEpoch > 0 && tsUS > 0 && tsUS <= maxReasonableTsUS {
		computed := bootEpoch + tsUS*1000
		if computed >= minValidTimestampNs && computed <= now+maxFutureSkewNs {
			return uint64(computed)
		}
	}
	return uint64(now)
}

// parseKmsgLine parses a /dev/kmsg record of the form:
//
//	priority,sequence,timestamp_us,-;message
//
// Returns the syslog level (0–7), sanitised message text, timestamp in
// microseconds since boot, and whether parsing succeeded. ASCII and Unicode
// control characters (except tab) are stripped to prevent log injection.
func parseKmsgLine(line string) (level int, message string, timestampUS int64, ok bool) {
	semi := strings.IndexByte(line, ';')
	if semi < 0 {
		return 0, "", 0, false
	}

	// Strip ASCII control chars and Unicode format/control characters.
	message = strings.Map(func(r rune) rune {
		if r == '\t' {
			return r
		}
		// Drop ASCII control chars (C0/C1) and selected Unicode characters that
		// could be used for log injection or terminal escape sequences:
		//   0x200B zero-width space, 0x200E/0x200F directional marks, 0xFEFF BOM
		//   0x2028–0x2029 line/paragraph separators
		//   0x202A–0x202E bidirectional override characters (LRE/RLE/PDF/LRO/RLO)
		//   0x2066–0x2069 bidirectional isolation characters (LRI/RLI/FSI/PDI)
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) ||
			r == 0x200b || r == 0x200e || r == 0x200f || r == 0xfeff ||
			(r >= 0x2028 && r <= 0x202e) ||
			(r >= 0x2066 && r <= 0x2069) {
			return -1
		}
		return r
	}, line[semi+1:])
	// Strip orphaned CSI remnants (e.g. "[31m") left after ESC is removed above.
	message = csiRemnantPattern.ReplaceAllString(message, "")

	parts := strings.SplitN(line[:semi], ",", 4)
	if len(parts) < 3 {
		return 0, "", 0, false
	}

	priority, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, "", 0, false
	}
	// The kmsg priority byte is facility|level (8 bits). Reject values outside
	// this range — a negative or oversized value indicates a crafted/malformed
	// record and could silently coerce to an unexpected severity via & 7.
	if priority < 0 || priority > 0xFF {
		return 0, "", 0, false
	}

	ts, _ := strconv.ParseInt(parts[2], 10, 64)
	// Reject negative timestamps for consistency with the priority bounds check
	// above; kmsgTimestampToWall guards against this too, but explicit rejection
	// here prevents surprises if the caller is ever extended.
	if ts < 0 {
		return 0, "", 0, false
	}
	return priority & 7, message, ts, true
}

// kernelLevelToOTEL maps a kernel syslog level (0–7) to an OTel severity.
// Non-critical levels are mapped into the trace/debug band so they do not
// pollute default INFO+ views. Critical levels (KERN_CRIT and above) are
// mapped to their natural OTel equivalents so they remain visible in SIEM
// alerting pipelines (SOC2-CC7, ISO27001-A.12, NIST-AU-2).
func kernelLevelToOTEL(level int) (otelpb.SeverityNumber, string) {
	switch level {
	case 7: // KERN_DEBUG
		return otelpb.SeverityNumber_SEVERITY_NUMBER_TRACE, "TRACE"
	case 6: // KERN_INFO
		return otelpb.SeverityNumber_SEVERITY_NUMBER_TRACE4, "TRACE"
	case 5: // KERN_NOTICE
		return otelpb.SeverityNumber_SEVERITY_NUMBER_DEBUG, "DEBUG"
	case 4: // KERN_WARNING
		return otelpb.SeverityNumber_SEVERITY_NUMBER_DEBUG2, "DEBUG"
	case 3: // KERN_ERR
		return otelpb.SeverityNumber_SEVERITY_NUMBER_DEBUG3, "DEBUG"
	case 2: // KERN_CRIT
		return otelpb.SeverityNumber_SEVERITY_NUMBER_WARN, "WARN"
	case 1: // KERN_ALERT
		return otelpb.SeverityNumber_SEVERITY_NUMBER_ERROR, "ERROR"
	default: // KERN_EMERG (0)
		return otelpb.SeverityNumber_SEVERITY_NUMBER_FATAL, "FATAL"
	}
}
