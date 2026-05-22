//go:build linux

package services

import (
	"bufio"
	"context"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
	"golang.org/x/sys/unix"

	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

const (
	// dmesgMaxMsgsPerSec caps how many kernel messages are forwarded per second.
	// During a kernel message burst (network storm, hardware fault) the kernel
	// can emit thousands of messages/s; without this cap the scanner loop would
	// saturate the broadcaster and degrade agent availability.
	dmesgMaxMsgsPerSec = 500

	// dmesgMaxMessageLen is the maximum byte length of a single kernel message
	// body. The kernel's internal limit is ~1 KB but we clamp defensively.
	dmesgMaxMessageLen = 4096

	// minValidTimestampNs rejects computed timestamps earlier than year 2000
	// as a guard against NTP step / boot-epoch computation errors.
	minValidTimestampNs = 946684800 * int64(time.Second)

	// maxFutureSkewNs rejects timestamps more than 24 h in the future.
	maxFutureSkewNs = int64(24 * time.Hour)
)

// CollectDmesgLogs reads kernel messages from /dev/kmsg and publishes them as
// OTel log records at debug/trace severity. It replays buffered kernel messages
// first, then follows new ones. Blocks until ctx is cancelled.
//
// NOTE: Raw kernel messages frequently contain operationally sensitive data
// (MAC addresses, USB serial numbers, process names/PIDs, filesystem paths).
// Callers should ensure the OTLP destination's data-processing agreement covers
// this content and that local data-minimisation requirements are met.
//
// NOTE: All kernel severity levels (including KERN_EMERG/ALERT/CRIT) are
// intentionally mapped into the OTel debug/trace band so dmesg output does not
// surface in default INFO+ log views. See kernelLevelToOTEL for the mapping.
// Operators who need EMERG/CRIT kernel events to trigger alerts should configure
// a separate alerting path (e.g., /proc/kmsg reader or systemd journal forwarder)
// rather than relying on this telemetry stream.
func CollectDmesgLogs(ctx context.Context, logger *zap.Logger, broadcaster *TelemetryBroadcaster) {
	f, err := os.Open("/dev/kmsg")
	if err != nil {
		logger.Warn("dmesg collection unavailable", zap.Error(err))
		return
	}

	// Use sync.Once so both the ctx-cancel goroutine and the defer always
	// attempt to close the file, but only one close actually happens — avoiding
	// the fd-reuse race that a double close() would introduce.
	var closeOnce sync.Once
	closeFile := func() { closeOnce.Do(func() { _ = f.Close() }) }
	go func() {
		<-ctx.Done()
		closeFile()
	}()
	defer closeFile()

	resource := dmesgResource()
	bootEpoch := kmsgBootEpochNanoseconds()

	// Simple sliding-window rate limiter: allow up to dmesgMaxMsgsPerSec
	// messages per second; drop excess and log a summary of dropped messages.
	var (
		windowStart = time.Now()
		windowCount int
		windowDrop  int
	)
	rateAllow := func() bool {
		now := time.Now()
		if now.Sub(windowStart) >= time.Second {
			if windowDrop > 0 {
				logger.Debug("dmesg rate limit: messages dropped in last second",
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
			// Continuation lines carry key=value device metadata — skip them.
			continue
		}

		level, message, tsUS, ok := parseKmsgLine(line)
		if !ok {
			continue
		}
		if len(message) > dmesgMaxMessageLen {
			message = message[:dmesgMaxMessageLen]
		}

		if !rateAllow() {
			continue
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
// a wall-clock Unix nanosecond value. If the computed value falls outside a
// plausible range (before year 2000, or more than 24 h in the future) it falls
// back to time.Now() to guard against NTP steps or boot-epoch skew.
func kmsgTimestampToWall(tsUS int64, bootEpoch int64) uint64 {
	now := time.Now().UnixNano()
	if bootEpoch > 0 && tsUS > 0 {
		computed := bootEpoch + tsUS*1000
		if computed >= minValidTimestampNs && computed-now <= maxFutureSkewNs {
			return uint64(computed)
		}
	}
	return uint64(now)
}

// parseKmsgLine parses a /dev/kmsg record of the form:
//
//	priority,sequence,timestamp_us,-;message
//
// Returns the syslog level (0–7), message text, timestamp in microseconds
// since boot, and whether parsing succeeded.
func parseKmsgLine(line string) (level int, message string, timestampUS int64, ok bool) {
	semi := strings.IndexByte(line, ';')
	if semi < 0 {
		return 0, "", 0, false
	}
	message = line[semi+1:]

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
// within the debug/trace band. Kernel debug messages map to trace; higher
// kernel severity maps upward within the debug sub-levels so that relative
// ordering is preserved while keeping all dmesg output below INFO.
//
// KERN_EMERG (0), KERN_ALERT (1), and KERN_CRIT (2) are intentionally capped
// at DEBUG4 rather than mapped to FATAL/ERROR. This is a deliberate design
// choice: these events are collected for diagnostic purposes and should not
// surface in default INFO+ alert rules. See the CollectDmesgLogs doc comment
// for guidance on routing critical kernel events to separate alert channels.
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
