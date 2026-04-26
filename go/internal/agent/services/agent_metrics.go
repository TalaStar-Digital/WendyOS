package services

import (
	"context"
	"runtime"
	"syscall"
	"time"

	"github.com/wendylabsinc/wendy/internal/shared/version"
	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// CollectAgentMetrics periodically samples the wendy-agent process's CPU and
// memory and publishes them as OTel metrics using process.* semconv names.
func CollectAgentMetrics(ctx context.Context, broadcaster *TelemetryBroadcaster, hostname string) {
	resource := agentMetricResource(hostname)
	ticker := time.NewTicker(metricsCollectionInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case t := <-ticker.C:
			user, sys := agentCPUNanos()
			mem := agentMemBytes()
			publishProcessMetrics(broadcaster, resource, "wendy.agent",
				"process.cpu.time", "process.memory.usage",
				user, sys, mem, t)
		}
	}
}

func agentMetricResource(hostname string) *otelpb.Resource {
	attrs := []*otelpb.KeyValue{
		stringKV("service.name", "wendy-agent"),
		stringKV("service.namespace", "wendy"),
		stringKV("service.version", version.Version),
	}
	if hostname != "" {
		attrs = append(attrs, stringKV("service.instance.id", hostname))
	}
	return &otelpb.Resource{Attributes: attrs}
}

func agentCPUNanos() (userNanos, sysNanos int64) {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		return 0, 0
	}
	userNanos = usage.Utime.Sec*1_000_000_000 + int64(usage.Utime.Usec)*1_000
	sysNanos = usage.Stime.Sec*1_000_000_000 + int64(usage.Stime.Usec)*1_000
	return
}

func agentMemBytes() int64 {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return int64(ms.Sys)
}
