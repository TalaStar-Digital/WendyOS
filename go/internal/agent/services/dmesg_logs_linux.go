//go:build linux

package services

import (
	"bufio"
	"context"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
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
)

// piiPatterns matches host-identifying values in kernel messages for redaction
// when WENDY_DMESG_REDACT is enabled:
//   - MAC addresses (colon and hyphen separated)
//   - IPv4 addresses
//   - USB SerialNumber values (GDPR Recital 30: device serial numbers are PII)
//   - Process names and PIDs in OOM killer messages
//
// IPv6 is intentionally omitted: a simple colon-hex pattern has too many false
// positives in kernel messages; proper IPv6 redaction requires a dedicated
// parser that is out of scope here.
var piiPatterns = regexp.MustCompile(
	`(?i)(?:` +
		// MAC address (colon separated, exactly 6 octets)
		`(?:[0-9a-f]{2}:){5}[0-9a-f]{2}` +
		// MAC address (hyphen separated, exactly 6 octets)
		`|(?:[0-9a-f]{2}-){5}[0-9a-f]{2}` +
		// IPv4 address
		`|\b(?:\d{1,3}\.){3}\d{1,3}\b` +
		// USB serial number (e.g. "SerialNumber: ABC123DEF")
		`|SerialNumber:\s+\S+` +
		// OOM killer: process name+PID (e.g. "Kill process 1234 (nginx)")
		`|Kill(?:ed)?\s+process\s+\d+\s+\([^)]+\)` +
		`)`,
)

// csiRemnantPattern strips orphaned ANSI CSI sequences left after ESC (U+001B,
// removed by parseKmsgLine's r < 0x20 check) is stripped. Without this, a
// kernel message containing "\x1b[31m" would leave "[31m" in the output, which
// some log viewers render as an ANSI colour code.
var csiRemnantPattern = regexp.MustCompile(`\[[0-9;]*[A-Za-z]`)

// CollectDmesgLogs reads kernel messages from /dev/kmsg and publishes them as
// OTel log records at debug/trace severity. It replays buffered kernel messages
// first, then follows new ones. Blocks until ctx is cancelled.
//
// MAC addresses and IPv4 addresses are redacted by default (WENDY_DMESG_REDACT
// defaults to true). Set WENDY_DMESG_REDACT=false to disable. Note that kernel
// messages may also contain USB serial numbers, process names, PIDs, and
// filesystem paths that are not redacted by this best-effort filter; operators
// should review their data-minimisation requirements.
//
// NOTE: All kernel severity levels are intentionally mapped into the OTel
// debug/trace band. KERN_EMERG/ALERT/CRIT additionally emit a zap.Warn so
// they are visible in the agent's own log stream. See kernelLevelToOTEL.
func CollectDmesgLogs(ctx context.Context, logger *zap.Logger, broadcaster *TelemetryBroadcaster) {
	// Default redact to true (safe by default); only disable when explicitly set.
	redact := true
	if v, err := strconv.ParseBool(os.Getenv("WENDY_DMESG_REDACT")); err == nil {
		redact = v
	}

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

	logger.Info("kernel dmesg collection started",
		zap.String("source", "/dev/kmsg"),
		zap.Bool("redact", redact),
	)
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

	resource := dmesgResource()
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
	for scanner.Scan() {
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
		if redact {
			message = piiPatterns.ReplaceAllString(message, "<redacted>")
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
func dmesgResource() *otelpb.Resource {
	attrs := []*otelpb.KeyValue{
		stringKV("service.name", "kernel"),
		stringKV("service.namespace", "wendy"),
	}
	if h := resolveHostname(); h != "" {
		attrs = append(attrs, stringKV("service.instance.id", h))
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
		//   0x200B zero-width space, 0xFEFF BOM
		//   0x2028–0x2029 line/paragraph separators
		//   0x202A–0x202E bidirectional override characters (LRE/RLE/PDF/LRO/RLO)
		//   0x2066–0x2069 bidirectional isolation characters (LRI/RLI/FSI/PDI)
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) ||
			r == 0x200b || r == 0xfeff ||
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

	ts, _ := strconv.ParseInt(parts[2], 10, 64)
	return priority & 7, message, ts, true
}

// kernelLevelToOTEL maps a kernel syslog level (0–7) to an OTel severity
// within the debug/trace band, preserving relative ordering while keeping all
// dmesg output below INFO.
//
// KERN_EMERG (0), KERN_ALERT (1), and KERN_CRIT (2) are capped at DEBUG4 by
// design — these events are for diagnostic purposes and should not surface in
// default INFO+ alert rules. The scan loop in CollectDmesgLogs additionally
// emits a zap.Warn for these levels so they appear in the agent log stream,
// and they are exempt from rate limiting so they are never silently dropped.
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
	default: // KERN_CRIT (2), KERN_ALERT (1), KERN_EMERG (0)
		return otelpb.SeverityNumber_SEVERITY_NUMBER_DEBUG4, "DEBUG"
	}
}
