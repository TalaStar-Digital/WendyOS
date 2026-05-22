# OTel Disk Buffer & Cloud Flush — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buffer all OTel telemetry (logs, metrics, traces) to rotating segment files on disk so data survives network outages, flush continuously to cloud via `RemoteLoggingService.WriteLogEntries`, and let `wendy device logs --tail N` replay recent history.

**Architecture:** `TelemetryBuffer` wraps `TelemetryBroadcaster` — every `Publish*` call writes a 4-byte length-prefixed protobuf frame to the active segment file, then fans out to the broadcaster as before. `CloudFlusher` polls the segment files from a saved byte-offset cursor, sending batches to cloud and advancing the cursor on success. `StreamLogs/Metrics/Traces` get a new `last_n` field that replays history from disk before switching to the live channel.

**Tech Stack:** Go standard library (`encoding/binary`, `os`, `io`, `sort`), `google.golang.org/protobuf/proto`, `go.uber.org/zap`, `protoc`/`protoc-gen-go`/`protoc-gen-go-grpc` for proto codegen, `github.com/wendylabsinc/wendy/internal/agent/mtls` for mTLS dial.

---

## File Map

| File | Action |
|---|---|
| `internal/agent/services/telemetry_buffer.go` | Create — TelemetryBuffer: write path, rotation, eviction, ReadLastN, cursor I/O |
| `internal/agent/services/telemetry_buffer_test.go` | Create — unit tests for all TelemetryBuffer behaviour |
| `internal/agent/services/cloud_flusher.go` | Create — CloudFlusher: reads from disk, calls WriteLogEntries, retry/backoff |
| `internal/agent/services/cloud_flusher_test.go` | Create — unit tests with fake cloud client |
| `internal/agent/services/telemetry_service.go` | Modify — add `last_n` history replay in StreamLogs/Metrics/Traces |
| `internal/agent/services/telemetry_service_v2.go` | Modify — mirror last_n changes for v2 service |
| `internal/agent/services/telemetry_service_test.go` | Modify — add tests for last_n history + is_history flag |
| `cmd/wendy-agent/main.go` | Modify — construct TelemetryBuffer, pass to all Publish callers, start CloudFlusher |
| `Proto/wendy/agent/services/v1/wendy_agent_v1_telemetry_service.proto` | Modify — add last_n + is_history |
| `Proto/wendy/agent/services/v2/telemetry_service.proto` | Modify — same additions |
| `internal/cli/commands/device.go` | Modify — add --tail N flag to `wendy device logs` |

---

### Task 1: Create worktree and feature branch

**Files:** none (git setup only)

- [ ] **Step 1: Create the branch and worktree**

```bash
cd /path/to/wendyos
git worktree add .worktrees/otel-disk-buffer -b feat/otel-disk-buffer
```

- [ ] **Step 2: Verify**

```bash
git worktree list
```

Expected: new entry for `.worktrees/otel-disk-buffer` on branch `feat/otel-disk-buffer`.

All remaining tasks run from `.worktrees/otel-disk-buffer/go/`.

---

### Task 2: Segment file primitives

**Files:**
- Create: `internal/agent/services/telemetry_buffer.go` (helpers only — no TelemetryBuffer struct yet)
- Create: `internal/agent/services/telemetry_buffer_test.go`

These helpers are used by every subsequent task. Get them right here.

- [ ] **Step 1: Write the failing tests**

Create `internal/agent/services/telemetry_buffer_test.go`:

```go
package services

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"

	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// writeFrameTo is a test helper that writes a single length-prefixed frame.
func writeFrameTo(t *testing.T, path string, msg proto.Message) {
	t.Helper()
	data, err := proto.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(data)))
	f.Write(hdr[:])
	f.Write(data)
}

func TestSegmentFilename(t *testing.T) {
	got := segmentFilename(SignalLogs, 1)
	if got != "logs-000001.bin" {
		t.Errorf("want logs-000001.bin, got %s", got)
	}
	got = segmentFilename(SignalMetrics, 42)
	if got != "metrics-000042.bin" {
		t.Errorf("want metrics-000042.bin, got %s", got)
	}
}

func TestListSegments(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"logs-000002.bin", "logs-000001.bin", "metrics-000001.bin"} {
		os.WriteFile(filepath.Join(dir, name), []byte{}, 0644)
	}
	segs, err := listSegments(dir, SignalLogs)
	if err != nil {
		t.Fatal(err)
	}
	if len(segs) != 2 {
		t.Fatalf("want 2 log segments, got %d", len(segs))
	}
	if segs[0] != "logs-000001.bin" || segs[1] != "logs-000002.bin" {
		t.Errorf("wrong order: %v", segs)
	}
}

func TestReadFramesFrom_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs-000001.bin")

	entry := &otelpb.ExportLogsServiceRequest{
		ResourceLogs: []*otelpb.ResourceLogs{
			{ScopeLogs: []*otelpb.ScopeLogs{{
				LogRecords: []*otelpb.LogRecord{{
					Body: &otelpb.AnyValue{Value: &otelpb.AnyValue_StringValue{StringValue: "hello"}},
				}},
			}}},
		},
	}
	writeFrameTo(t, path, entry)
	writeFrameTo(t, path, entry)

	msgs, endOffset, err := readFramesFrom(path, 0, SignalLogs, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("want 2 messages, got %d", len(msgs))
	}
	if endOffset == 0 {
		t.Error("endOffset should be > 0")
	}
}

func TestReadFramesFrom_PartialFrame(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs-000001.bin")

	entry := &otelpb.ExportLogsServiceRequest{}
	writeFrameTo(t, path, entry)

	// Append a partial header (only 2 bytes — incomplete frame).
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	f.Write([]byte{0x00, 0x00})
	f.Close()

	msgs, _, err := readFramesFrom(path, 0, SignalLogs, 10)
	if err != nil {
		t.Fatal(err)
	}
	// Partial frame must be skipped; only the first complete entry returned.
	if len(msgs) != 1 {
		t.Errorf("want 1 message (partial frame skipped), got %d", len(msgs))
	}
}

func TestReadFramesFrom_MaxN(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs-000001.bin")
	entry := &otelpb.ExportLogsServiceRequest{}
	for i := 0; i < 5; i++ {
		writeFrameTo(t, path, entry)
	}
	msgs, _, _ := readFramesFrom(path, 0, SignalLogs, 3)
	if len(msgs) != 3 {
		t.Errorf("want 3 messages (maxN respected), got %d", len(msgs))
	}
}
```

- [ ] **Step 2: Run tests — expect failures**

```bash
go test ./internal/agent/services/... -run 'TestSegmentFilename|TestListSegments|TestReadFramesFrom' -v
```

Expected: compilation error — `segmentFilename`, `listSegments`, `readFramesFrom`, `SignalLogs` not defined.

- [ ] **Step 3: Implement the helpers**

Create `internal/agent/services/telemetry_buffer.go`:

```go
package services

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"google.golang.org/protobuf/proto"

	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// SignalType identifies a telemetry signal kind.
type SignalType string

const (
	SignalLogs    SignalType = "logs"
	SignalMetrics SignalType = "metrics"
	SignalTraces  SignalType = "traces"
)

// segmentFilename returns the filename for a segment file, e.g. "logs-000001.bin".
func segmentFilename(signal SignalType, seqNum int) string {
	return fmt.Sprintf("%s-%06d.bin", signal, seqNum)
}

// listSegments returns segment filenames (basename only) for signal, sorted
// ascending by sequence number. It does not prepend the directory.
func listSegments(dir string, signal SignalType) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	prefix := string(signal) + "-"
	var names []string
	for _, e := range entries {
		n := e.Name()
		if !e.IsDir() && strings.HasPrefix(n, prefix) && strings.HasSuffix(n, ".bin") {
			names = append(names, n)
		}
	}
	sort.Strings(names) // zero-padded seq → lexicographic = numeric order
	return names, nil
}

// newProtoForSignal allocates a fresh proto.Message of the correct type for signal.
func newProtoForSignal(signal SignalType) proto.Message {
	switch signal {
	case SignalLogs:
		return &otelpb.ExportLogsServiceRequest{}
	case SignalMetrics:
		return &otelpb.ExportMetricsServiceRequest{}
	case SignalTraces:
		return &otelpb.ExportTraceServiceRequest{}
	default:
		return nil
	}
}

// readFramesFrom reads up to maxN length-prefixed protobuf frames from path
// starting at startOffset. Returns the decoded messages, the byte offset after
// the last successfully read frame, and any I/O error (os.ErrNotExist included).
// A partial or corrupted frame at the end of the file is silently skipped.
func readFramesFrom(path string, startOffset int64, signal SignalType, maxN int) ([]proto.Message, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, startOffset, err
	}
	defer f.Close()

	if startOffset > 0 {
		if _, err := f.Seek(startOffset, io.SeekStart); err != nil {
			return nil, startOffset, err
		}
	}

	offset := startOffset
	var msgs []proto.Message

	for len(msgs) < maxN {
		var hdr [4]byte
		if _, err := io.ReadFull(f, hdr[:]); err != nil {
			break // EOF or partial header — stop cleanly
		}
		length := binary.BigEndian.Uint32(hdr[:])
		if length == 0 || length > 10*1024*1024 { // sanity: skip corrupt header
			break
		}
		data := make([]byte, length)
		if _, err := io.ReadFull(f, data); err != nil {
			break // partial payload — stop cleanly
		}
		msg := newProtoForSignal(signal)
		if msg == nil {
			break
		}
		if err := proto.Unmarshal(data, msg); err != nil {
			// Corrupted frame: skip it and keep reading.
			offset += int64(4 + length)
			continue
		}
		msgs = append(msgs, msg)
		offset += int64(4 + length)
	}

	return msgs, offset, nil
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
go test ./internal/agent/services/... -run 'TestSegmentFilename|TestListSegments|TestReadFramesFrom' -v
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add internal/agent/services/telemetry_buffer.go internal/agent/services/telemetry_buffer_test.go
git commit -m "feat: add segment file primitives for OTel disk buffer"
```

---

### Task 3: TelemetryBuffer — write path, rotation, and eviction

**Files:**
- Modify: `internal/agent/services/telemetry_buffer.go` (add struct + Publish* + rotation)
- Modify: `internal/agent/services/telemetry_buffer_test.go` (add write/rotate/evict tests)

- [ ] **Step 1: Add the write tests**

Append to `internal/agent/services/telemetry_buffer_test.go`:

```go
func makeTestBuffer(t *testing.T, maxTotal, segmentSize int64) (*TelemetryBuffer, string) {
	t.Helper()
	dir := t.TempDir()
	broadcaster := NewTelemetryBroadcaster()
	cfg := TelemetryBufferConfig{
		Dir:           dir,
		MaxTotalBytes: maxTotal,
		SegmentBytes:  segmentSize,
	}
	buf, err := NewTelemetryBuffer(cfg, broadcaster, nopLogger())
	if err != nil {
		t.Fatalf("NewTelemetryBuffer: %v", err)
	}
	return buf, dir
}

func nopLogger() *zap.Logger { return zap.NewNop() }

func makeLogReq(body string) *otelpb.ExportLogsServiceRequest {
	return &otelpb.ExportLogsServiceRequest{
		ResourceLogs: []*otelpb.ResourceLogs{{
			ScopeLogs: []*otelpb.ScopeLogs{{
				LogRecords: []*otelpb.LogRecord{{
					Body: &otelpb.AnyValue{Value: &otelpb.AnyValue_StringValue{StringValue: body}},
				}},
			}},
		}},
	}
}

func TestTelemetryBuffer_WriteAndRead(t *testing.T) {
	buf, dir := makeTestBuffer(t, 10*1024*1024, 1*1024*1024)

	buf.PublishLogs(makeLogReq("first"))
	buf.PublishLogs(makeLogReq("second"))

	segs, _ := listSegments(dir, SignalLogs)
	if len(segs) == 0 {
		t.Fatal("expected at least one segment file")
	}
	msgs, _, _ := readFramesFrom(filepath.Join(dir, segs[len(segs)-1]), 0, SignalLogs, 10)
	if len(msgs) != 2 {
		t.Fatalf("want 2 frames on disk, got %d", len(msgs))
	}
}

func TestTelemetryBuffer_Rotation(t *testing.T) {
	// Set segment size tiny (50 bytes) to force rotation after ~1 entry.
	buf, dir := makeTestBuffer(t, 10*1024*1024, 50)

	for i := 0; i < 5; i++ {
		buf.PublishLogs(makeLogReq("entry"))
	}

	segs, _ := listSegments(dir, SignalLogs)
	if len(segs) < 2 {
		t.Errorf("expected multiple segments after rotation, got %d", len(segs))
	}
}

func TestTelemetryBuffer_Eviction(t *testing.T) {
	// MaxTotalBytes = 200, SegmentBytes = 50 → evicts oldest when cap exceeded.
	buf, dir := makeTestBuffer(t, 200, 50)

	for i := 0; i < 20; i++ {
		buf.PublishLogs(makeLogReq("entry"))
	}

	// Total size must not exceed MaxTotalBytes.
	var total int64
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".bin") {
			fi, _ := e.Info()
			total += fi.Size()
		}
	}
	if total > 200 {
		t.Errorf("total segment size %d exceeds cap 200", total)
	}
	_ = buf
}

func TestTelemetryBuffer_BroadcastStillFires(t *testing.T) {
	buf, _ := makeTestBuffer(t, 1*1024*1024, 512*1024)
	_, ch := buf.broadcaster.SubscribeLogs()

	buf.PublishLogs(makeLogReq("live"))

	select {
	case msg := <-ch:
		if msg == nil {
			t.Error("received nil from broadcast channel")
		}
	case <-time.After(time.Second):
		t.Error("broadcast did not fire within 1s")
	}
}
```

Note: add `"time"` and `"strings"` to the existing import block in the test file.

- [ ] **Step 2: Run tests — expect failure**

```bash
go test ./internal/agent/services/... -run 'TestTelemetryBuffer' -v
```

Expected: compile error — `TelemetryBufferConfig`, `NewTelemetryBuffer`, `.broadcaster` not defined.

- [ ] **Step 3: Implement TelemetryBuffer struct and write path**

Append to `internal/agent/services/telemetry_buffer.go`:

```go
import (
	// add to existing import block:
	"path/filepath"
	"sync"

	"go.uber.org/zap"
)

const (
	defaultMaxTotalBytes int64 = 100 * 1024 * 1024 // 100 MB
	defaultSegmentBytes  int64 = 4 * 1024 * 1024   // 4 MB
	defaultTelemetryDir        = "/var/lib/wendy-agent/telemetry"
)

// TelemetryBufferConfig configures TelemetryBuffer storage limits.
type TelemetryBufferConfig struct {
	Dir           string // defaults to $WENDY_TELEMETRY_DIR or /var/lib/wendy-agent/telemetry
	MaxTotalBytes int64  // defaults to 100 MB
	SegmentBytes  int64  // defaults to 4 MB
}

func (c *TelemetryBufferConfig) applyDefaults() {
	if c.Dir == "" {
		if d := os.Getenv("WENDY_TELEMETRY_DIR"); d != "" {
			c.Dir = d
		} else {
			c.Dir = defaultTelemetryDir
		}
	}
	if c.MaxTotalBytes == 0 {
		c.MaxTotalBytes = defaultMaxTotalBytes
	}
	if c.SegmentBytes == 0 {
		c.SegmentBytes = defaultSegmentBytes
	}
}

// flushCursor records the position up to which data has been confirmed
// delivered to cloud for a single signal type.
type flushCursor struct {
	File   string `json:"file"`
	Offset int64  `json:"offset"`
}

type segWriter struct {
	f      *os.File
	size   int64
	seqNum int
}

// TelemetryBuffer persists OTel telemetry to rotating segment files and
// fans out to an in-memory TelemetryBroadcaster.
type TelemetryBuffer struct {
	cfg         TelemetryBufferConfig
	broadcaster *TelemetryBroadcaster
	logger      *zap.Logger
	mu          sync.Mutex
	writers     map[SignalType]*segWriter
}

// NewTelemetryBuffer creates a TelemetryBuffer, creating the storage directory
// if needed. Falls back gracefully if the directory cannot be created: returns
// a buffer that only fans out to the broadcaster (no disk writes).
func NewTelemetryBuffer(cfg TelemetryBufferConfig, broadcaster *TelemetryBroadcaster, logger *zap.Logger) (*TelemetryBuffer, error) {
	cfg.applyDefaults()

	if err := os.MkdirAll(cfg.Dir, 0755); err != nil {
		logger.Warn("telemetry buffer: cannot create dir, disk writes disabled", zap.Error(err))
		// Still return a usable buffer — writes will be no-ops.
		return &TelemetryBuffer{
			cfg:         cfg,
			broadcaster: broadcaster,
			logger:      logger,
			writers:     make(map[SignalType]*segWriter),
		}, nil
	}

	b := &TelemetryBuffer{
		cfg:         cfg,
		broadcaster: broadcaster,
		logger:      logger,
		writers:     make(map[SignalType]*segWriter),
	}

	b.evictIfNeeded() // prune on startup if dir already over cap

	for _, sig := range []SignalType{SignalLogs, SignalMetrics, SignalTraces} {
		if err := b.openLatestWriter(sig); err != nil {
			return nil, fmt.Errorf("opening writer for %s: %w", sig, err)
		}
	}

	return b, nil
}

// openLatestWriter opens the highest-sequence segment for sig (or creates
// sequence 000001 if none exist). Must be called before the first write.
// Caller must not hold b.mu.
func (b *TelemetryBuffer) openLatestWriter(sig SignalType) error {
	segs, _ := listSegments(b.cfg.Dir, sig)
	seqNum := 1
	if len(segs) > 0 {
		last := segs[len(segs)-1]
		// Parse seqNum from e.g. "logs-000003.bin"
		trimmed := strings.TrimPrefix(last, string(sig)+"-")
		trimmed = strings.TrimSuffix(trimmed, ".bin")
		if n, err := fmt.Sscanf(trimmed, "%d", &seqNum); n != 1 || err != nil {
			seqNum = len(segs) + 1
		}
	}

	path := filepath.Join(b.cfg.Dir, segmentFilename(sig, seqNum))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	fi, _ := f.Stat()
	var size int64
	if fi != nil {
		size = fi.Size()
	}
	b.writers[sig] = &segWriter{f: f, size: size, seqNum: seqNum}
	return nil
}

// rotateWriter seals the current segment and opens the next. b.mu must be held.
func (b *TelemetryBuffer) rotateWriter(sig SignalType) error {
	w := b.writers[sig]
	if w != nil {
		w.f.Close()
	}
	seqNum := 1
	if w != nil {
		seqNum = w.seqNum + 1
	}
	path := filepath.Join(b.cfg.Dir, segmentFilename(sig, seqNum))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	b.writers[sig] = &segWriter{f: f, size: 0, seqNum: seqNum}
	b.evictIfNeeded()
	return nil
}

// evictIfNeeded deletes the oldest segment files across all signals until
// the total directory size is within MaxTotalBytes. b.mu may or may not be held;
// called at startup (single-threaded) and under b.mu after rotation.
func (b *TelemetryBuffer) evictIfNeeded() {
	for b.totalSegmentSize() > b.cfg.MaxTotalBytes {
		oldest := b.findOldestSegment()
		if oldest == "" {
			break
		}
		if err := os.Remove(filepath.Join(b.cfg.Dir, oldest)); err != nil && !os.IsNotExist(err) {
			b.logger.Warn("telemetry buffer: failed to evict segment", zap.String("file", oldest), zap.Error(err))
			break
		}
	}
}

func (b *TelemetryBuffer) totalSegmentSize() int64 {
	var total int64
	entries, _ := os.ReadDir(b.cfg.Dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".bin") {
			fi, _ := e.Info()
			if fi != nil {
				total += fi.Size()
			}
		}
	}
	return total
}

// findOldestSegment returns the basename of the oldest segment across all
// signal types, or "" if no segments exist.
func (b *TelemetryBuffer) findOldestSegment() string {
	var candidates []string
	for _, sig := range []SignalType{SignalLogs, SignalMetrics, SignalTraces} {
		segs, _ := listSegments(b.cfg.Dir, sig)
		// Skip the active segment (don't evict what we're writing to).
		w := b.writers[sig]
		activeSeq := -1
		if w != nil {
			activeSeq = w.seqNum
		}
		for _, s := range segs {
			var seq int
			fmt.Sscanf(strings.TrimSuffix(strings.TrimPrefix(s, string(sig)+"-"), ".bin"), "%d", &seq)
			if seq != activeSeq {
				candidates = append(candidates, s)
			}
		}
	}
	if len(candidates) == 0 {
		return ""
	}
	sort.Strings(candidates)
	return candidates[0]
}

// writeFrame serialises msg and appends it to the active segment for sig.
// Disk errors are logged and swallowed — the caller's broadcast is unaffected.
func (b *TelemetryBuffer) writeFrame(sig SignalType, msg proto.Message) {
	data, err := proto.Marshal(msg)
	if err != nil {
		b.logger.Warn("telemetry buffer: marshal failed", zap.Error(err))
		return
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	w := b.writers[sig]
	if w == nil {
		return // directory unavailable
	}

	needed := int64(4 + len(data))
	if w.size > 0 && w.size+needed > b.cfg.SegmentBytes {
		if err := b.rotateWriter(sig); err != nil {
			b.logger.Warn("telemetry buffer: rotation failed", zap.String("signal", string(sig)), zap.Error(err))
			return
		}
		w = b.writers[sig]
	}

	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(data)))
	if _, err := w.f.Write(hdr[:]); err != nil {
		b.logger.Warn("telemetry buffer: write header failed", zap.Error(err))
		return
	}
	if _, err := w.f.Write(data); err != nil {
		b.logger.Warn("telemetry buffer: write payload failed", zap.Error(err))
		return
	}
	w.size += needed
}

// PublishLogs writes req to disk then fans out to the broadcaster.
func (b *TelemetryBuffer) PublishLogs(req *otelpb.ExportLogsServiceRequest) {
	b.writeFrame(SignalLogs, req)
	b.broadcaster.PublishLogs(req)
}

// PublishMetrics writes req to disk then fans out to the broadcaster.
func (b *TelemetryBuffer) PublishMetrics(req *otelpb.ExportMetricsServiceRequest) {
	b.writeFrame(SignalMetrics, req)
	b.broadcaster.PublishMetrics(req)
}

// PublishTraces writes req to disk then fans out to the broadcaster.
func (b *TelemetryBuffer) PublishTraces(req *otelpb.ExportTraceServiceRequest) {
	b.writeFrame(SignalTraces, req)
	b.broadcaster.PublishTraces(req)
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
go test ./internal/agent/services/... -run 'TestTelemetryBuffer' -v
```

Expected: all 4 `TestTelemetryBuffer_*` tests pass.

- [ ] **Step 5: Commit**

```bash
git add internal/agent/services/telemetry_buffer.go internal/agent/services/telemetry_buffer_test.go
git commit -m "feat: add TelemetryBuffer write path with segment rotation and eviction"
```

---

### Task 4: TelemetryBuffer — ReadLastN and cursor helpers

**Files:**
- Modify: `internal/agent/services/telemetry_buffer.go` (add ReadLastN, ReadFromCursor, SaveCursor, LoadCursor)
- Modify: `internal/agent/services/telemetry_buffer_test.go` (add ReadLastN + cursor tests)

- [ ] **Step 1: Add the tests**

Append to `internal/agent/services/telemetry_buffer_test.go`:

```go
func TestTelemetryBuffer_ReadLastN(t *testing.T) {
	// Use tiny segments (50 bytes) so 5 entries span multiple segments.
	buf, dir := makeTestBuffer(t, 10*1024*1024, 50)

	bodies := []string{"a", "b", "c", "d", "e"}
	for _, b := range bodies {
		buf.PublishLogs(makeLogReq(b))
	}

	msgs := buf.ReadLastN(SignalLogs, 3)
	if len(msgs) != 3 {
		t.Fatalf("want 3 messages, got %d", len(msgs))
	}
	// Should be c, d, e in order.
	for i, want := range []string{"c", "d", "e"} {
		req := msgs[i].(*otelpb.ExportLogsServiceRequest)
		got := req.GetResourceLogs()[0].GetScopeLogs()[0].GetLogRecords()[0].GetBody().GetStringValue()
		if got != want {
			t.Errorf("msg[%d]: want %q, got %q", i, want, got)
		}
	}
	_ = dir
}

func TestTelemetryBuffer_ReadLastN_FewerThanN(t *testing.T) {
	buf, _ := makeTestBuffer(t, 10*1024*1024, 1*1024*1024)
	buf.PublishLogs(makeLogReq("only"))

	msgs := buf.ReadLastN(SignalLogs, 100)
	if len(msgs) != 1 {
		t.Errorf("want 1 message, got %d", len(msgs))
	}
}

func TestTelemetryBuffer_Cursor(t *testing.T) {
	buf, dir := makeTestBuffer(t, 10*1024*1024, 1*1024*1024)
	buf.PublishLogs(makeLogReq("x"))
	buf.PublishLogs(makeLogReq("y"))

	// Cursor starts at zero (nothing flushed yet).
	cur := buf.LoadCursor(SignalLogs)
	if cur.Offset != 0 {
		t.Errorf("expected zero cursor, got offset %d", cur.Offset)
	}

	// Read from cursor and advance it.
	msgs, next, err := buf.ReadFromCursor(SignalLogs, cur, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Errorf("want 2 messages from cursor, got %d", len(msgs))
	}

	// Save + reload cursor.
	if err := buf.SaveCursor(SignalLogs, next); err != nil {
		t.Fatal(err)
	}
	reloaded := buf.LoadCursor(SignalLogs)
	if reloaded.File != next.File || reloaded.Offset != next.Offset {
		t.Errorf("cursor reload mismatch: want %+v, got %+v", next, reloaded)
	}

	// Reading again from the saved cursor returns nothing.
	msgs2, _, _ := buf.ReadFromCursor(SignalLogs, reloaded, 10)
	if len(msgs2) != 0 {
		t.Errorf("expected no new messages after cursor advanced, got %d", len(msgs2))
	}

	_ = dir
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
go test ./internal/agent/services/... -run 'TestTelemetryBuffer_ReadLastN|TestTelemetryBuffer_Cursor' -v
```

Expected: compile error — `ReadLastN`, `ReadFromCursor`, `SaveCursor`, `LoadCursor` not defined.

- [ ] **Step 3: Implement ReadLastN, ReadFromCursor, SaveCursor, LoadCursor**

Append to `internal/agent/services/telemetry_buffer.go`:

```go
import (
	// add to existing import block:
	"encoding/json"
	"path/filepath"
)

const cursorFile = "cursor.json"

type cursorMap map[SignalType]flushCursor

// LoadCursor returns the persisted flush cursor for sig, or a zero cursor if
// cursor.json is absent or does not contain an entry for sig.
func (b *TelemetryBuffer) LoadCursor(sig SignalType) flushCursor {
	data, err := os.ReadFile(filepath.Join(b.cfg.Dir, cursorFile))
	if err != nil {
		return flushCursor{}
	}
	var m cursorMap
	if err := json.Unmarshal(data, &m); err != nil {
		return flushCursor{}
	}
	return m[sig]
}

// SaveCursor persists cursor for sig to cursor.json atomically.
func (b *TelemetryBuffer) SaveCursor(sig SignalType, cursor flushCursor) error {
	path := filepath.Join(b.cfg.Dir, cursorFile)
	// Read existing cursors, update, write back.
	var m cursorMap
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &m) //nolint:errcheck
	}
	if m == nil {
		m = make(cursorMap)
	}
	m[sig] = cursor
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ReadLastN returns up to n recent entries for sig in ascending time order
// (oldest first, newest last), reading backwards across segment files.
func (b *TelemetryBuffer) ReadLastN(sig SignalType, n int) []proto.Message {
	if n <= 0 {
		return nil
	}
	segs, _ := listSegments(b.cfg.Dir, sig)
	var result []proto.Message
	// Walk newest to oldest.
	for i := len(segs) - 1; i >= 0 && len(result) < n; i-- {
		frames, _, _ := readFramesFrom(filepath.Join(b.cfg.Dir, segs[i]), 0, sig, n)
		need := n - len(result)
		if len(frames) > need {
			frames = frames[len(frames)-need:]
		}
		result = append(frames, result...) // prepend older frames
	}
	return result
}

// ReadFromCursor reads up to maxN frames starting at cursor for sig.
// Returns the frames, the updated cursor, and any I/O error.
// If cursor.File is empty, reading starts from the oldest segment.
// If cursor.File no longer exists (evicted), reading starts from the current oldest.
func (b *TelemetryBuffer) ReadFromCursor(sig SignalType, cursor flushCursor, maxN int) ([]proto.Message, flushCursor, error) {
	segs, err := listSegments(b.cfg.Dir, sig)
	if err != nil || len(segs) == 0 {
		return nil, cursor, err
	}

	startFile := cursor.File
	startOffset := cursor.Offset

	// If no cursor yet, begin at the oldest segment.
	if startFile == "" {
		startFile = segs[0]
		startOffset = 0
	}

	// Find the index of the cursor file; fall back to oldest if it was evicted.
	startIdx := 0
	found := false
	for i, s := range segs {
		if s == startFile {
			startIdx = i
			found = true
			break
		}
	}
	if !found {
		// Cursor file evicted — start from current oldest.
		startIdx = 0
		startFile = segs[0]
		startOffset = 0
	}

	var msgs []proto.Message
	currentIdx := startIdx
	currentFile := startFile
	currentOffset := startOffset

	for len(msgs) < maxN && currentIdx < len(segs) {
		need := maxN - len(msgs)
		path := filepath.Join(b.cfg.Dir, segs[currentIdx])
		batch, endOffset, readErr := readFramesFrom(path, currentOffset, sig, need)

		if os.IsNotExist(readErr) {
			// Segment was evicted between listing and reading — skip it.
			currentIdx++
			if currentIdx < len(segs) {
				currentFile = segs[currentIdx]
				currentOffset = 0
			}
			continue
		}
		if readErr != nil {
			return msgs, flushCursor{File: currentFile, Offset: currentOffset}, readErr
		}

		msgs = append(msgs, batch...)
		currentFile = segs[currentIdx]
		currentOffset = endOffset

		if len(batch) < need {
			// File exhausted — advance to the next segment.
			currentIdx++
			if currentIdx < len(segs) {
				currentFile = segs[currentIdx]
				currentOffset = 0
			}
		} else {
			break
		}
	}

	return msgs, flushCursor{File: currentFile, Offset: currentOffset}, nil
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
go test ./internal/agent/services/... -run 'TestTelemetryBuffer' -v
```

Expected: all `TestTelemetryBuffer_*` tests pass.

- [ ] **Step 5: Commit**

```bash
git add internal/agent/services/telemetry_buffer.go internal/agent/services/telemetry_buffer_test.go
git commit -m "feat: add TelemetryBuffer ReadLastN and cursor persistence"
```

---

### Task 5: Proto changes and code regeneration

**Files:**
- Modify: `Proto/wendy/agent/services/v1/wendy_agent_v1_telemetry_service.proto`
- Modify: `Proto/wendy/agent/services/v2/telemetry_service.proto`
- Modify (generated): `proto/gen/agentpb/` and `proto/gen/agentpb/v2/`

- [ ] **Step 1: Edit the v1 proto**

In `Proto/wendy/agent/services/v1/wendy_agent_v1_telemetry_service.proto`, update all three request/response pairs:

```protobuf
message StreamLogsRequest {
    optional string service_name = 1;
    optional int32  min_severity = 2;
    optional string app_name     = 3;
    optional int32  last_n       = 4;  // replay last N log batches before going live
}

message StreamLogsResponse {
    opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest logs = 1;
    bool is_history = 2;  // true for replayed records; false for live
}

message StreamMetricsRequest {
    optional string service_name       = 1;
    optional string metric_name_prefix = 2;
    optional string app_name           = 3;
    optional int32  last_n             = 4;
}

message StreamMetricsResponse {
    opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest metrics = 1;
    bool is_history = 2;
}

message StreamTracesRequest {
    optional string service_name    = 1;
    optional string app_name        = 2;
    optional string span_name_prefix = 3;
    optional int32  last_n          = 4;
}

message StreamTracesResponse {
    opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest traces = 1;
    bool is_history = 2;
}
```

- [ ] **Step 2: Edit the v2 proto**

Apply identical changes to `Proto/wendy/agent/services/v2/telemetry_service.proto` (same field numbers, same field names).

- [ ] **Step 3: Regenerate**

```bash
cd /path/to/wendyos/go
make proto
```

Expected: `proto/gen/agentpb/wendy_agent_v1_telemetry_service.pb.go` and `proto/gen/agentpb/v2/telemetry_service.pb.go` regenerated; both now contain `LastN *int32` and `IsHistory bool` fields.

- [ ] **Step 4: Verify compilation**

```bash
go build ./...
```

Expected: clean compile (existing code that doesn't set `last_n` is unaffected since it's `optional`).

- [ ] **Step 5: Commit**

```bash
git add Proto/wendy/agent/services/v1/wendy_agent_v1_telemetry_service.proto \
        Proto/wendy/agent/services/v2/telemetry_service.proto \
        proto/gen/agentpb/ proto/gen/agentpb/v2/
git commit -m "feat: add last_n and is_history to telemetry stream proto"
```

---

### Task 6: TelemetryService history replay (v1 and v2)

**Files:**
- Modify: `internal/agent/services/telemetry_service.go`
- Modify: `internal/agent/services/telemetry_service_v2.go`
- Modify: `internal/agent/services/telemetry_service_test.go`

`TelemetryService` needs a reference to `*TelemetryBuffer` so it can call `ReadLastN`. The existing `NewTelemetryService` signature changes.

- [ ] **Step 1: Add the history replay tests**

Append to `internal/agent/services/telemetry_service_test.go`:

```go
func TestStreamLogs_LastN(t *testing.T) {
	dir := t.TempDir()
	broadcaster := NewTelemetryBroadcaster()
	buf, _ := NewTelemetryBuffer(TelemetryBufferConfig{
		Dir:           dir,
		MaxTotalBytes: 10 * 1024 * 1024,
		SegmentBytes:  1 * 1024 * 1024,
	}, broadcaster, zap.NewNop())

	// Write 5 log entries to disk before any client connects.
	for i := 0; i < 5; i++ {
		buf.PublishLogs(makeLogReq(fmt.Sprintf("msg-%d", i)))
	}

	svc := NewTelemetryService(zap.NewNop(), broadcaster, buf)

	// Stand up an in-process gRPC server.
	lis := bufconn.Listen(1024 * 1024)
	srv := grpc.NewServer()
	agentpb.RegisterWendyTelemetryServiceServer(srv, svc)
	go srv.Serve(lis) //nolint:errcheck
	defer srv.Stop()

	conn, _ := grpc.NewClient("passthrough://bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	defer conn.Close()

	client := agentpb.NewWendyTelemetryServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	lastN := int32(3)
	stream, err := client.StreamLogs(ctx, &agentpb.StreamLogsRequest{LastN: &lastN})
	if err != nil {
		t.Fatalf("StreamLogs: %v", err)
	}

	var historyCount int
	for i := 0; i < 3; i++ {
		resp, err := stream.Recv()
		if err != nil {
			t.Fatalf("Recv[%d]: %v", i, err)
		}
		if resp.IsHistory {
			historyCount++
		}
	}
	if historyCount != 3 {
		t.Errorf("want 3 history records, got %d", historyCount)
	}
}
```

Also add `"fmt"` to the import block of the test file if not already present.

- [ ] **Step 2: Run test — expect failure**

```bash
go test ./internal/agent/services/... -run 'TestStreamLogs_LastN' -v
```

Expected: compile error — `NewTelemetryService` signature mismatch; `IsHistory` not recognised.

- [ ] **Step 3: Update TelemetryService**

In `internal/agent/services/telemetry_service.go`, update the struct and constructor:

```go
// TelemetryService implements agentpb.WendyTelemetryServiceServer.
type TelemetryService struct {
	agentpb.UnimplementedWendyTelemetryServiceServer
	logger      *zap.Logger
	broadcaster *TelemetryBroadcaster
	buffer      *TelemetryBuffer // may be nil if disk buffering is unavailable
}

// NewTelemetryService creates a new TelemetryService.
// buffer may be nil; history replay is skipped when it is.
func NewTelemetryService(logger *zap.Logger, broadcaster *TelemetryBroadcaster, buffer *TelemetryBuffer) *TelemetryService {
	return &TelemetryService{
		logger:      logger,
		broadcaster: broadcaster,
		buffer:      buffer,
	}
}
```

Update `StreamLogs` to replay history before going live:

```go
func (s *TelemetryService) StreamLogs(req *agentpb.StreamLogsRequest, stream grpc.ServerStreamingServer[agentpb.StreamLogsResponse]) error {
	ctx := stream.Context()

	// Replay history if requested.
	if req.LastN != nil && *req.LastN > 0 && s.buffer != nil {
		entries := s.buffer.ReadLastN(SignalLogs, int(*req.LastN))
		for _, e := range entries {
			logs, ok := e.(*otelpb.ExportLogsServiceRequest)
			if !ok {
				continue
			}
			if req.AppName != nil || req.ServiceName != nil || req.MinSeverity != nil {
				logs = filterLogs(logs, req)
				if logs == nil {
					continue
				}
			}
			if err := stream.Send(&agentpb.StreamLogsResponse{Logs: logs, IsHistory: true}); err != nil {
				return err
			}
		}
	}

	id, ch := s.broadcaster.SubscribeLogs()
	defer s.broadcaster.UnsubscribeLogs(id)

	s.logger.Info("StreamLogs client connected", zap.String("sub_id", id))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case logReq, ok := <-ch:
			if !ok {
				return nil
			}
			if req.AppName != nil || req.ServiceName != nil || req.MinSeverity != nil {
				logReq = filterLogs(logReq, req)
				if logReq == nil {
					continue
				}
			}
			if err := stream.Send(&agentpb.StreamLogsResponse{Logs: logReq}); err != nil {
				return err
			}
		}
	}
}
```

Apply the same pattern to `StreamMetrics` (use `SignalMetrics`, `filterMetrics`, `agentpb.StreamMetricsResponse`) and `StreamTraces` (use `SignalTraces`, `filterTraces`, `agentpb.StreamTracesResponse`).

- [ ] **Step 4: Update TelemetryServiceV2**

In `internal/agent/services/telemetry_service_v2.go`, update the struct and constructor identically:

```go
type TelemetryServiceV2 struct {
	agentpbv2.UnimplementedWendyTelemetryServiceServer
	logger      *zap.Logger
	broadcaster *TelemetryBroadcaster
	buffer      *TelemetryBuffer
}

func NewTelemetryServiceV2(logger *zap.Logger, broadcaster *TelemetryBroadcaster, buffer *TelemetryBuffer) *TelemetryServiceV2 {
	return &TelemetryServiceV2{logger: logger, broadcaster: broadcaster, buffer: buffer}
}
```

Update `StreamLogs` in v2 identically to v1 (using `agentpbv2` types). Apply the same to `StreamMetrics` and `StreamTraces`.

- [ ] **Step 5: Run tests — expect pass**

```bash
go test ./internal/agent/services/... -v
```

Expected: all tests pass including `TestStreamLogs_LastN`.

- [ ] **Step 6: Commit**

```bash
git add internal/agent/services/telemetry_service.go \
        internal/agent/services/telemetry_service_v2.go \
        internal/agent/services/telemetry_service_test.go
git commit -m "feat: add last_n history replay to StreamLogs/Metrics/Traces"
```

---

### Task 7: CloudFlusher

**Files:**
- Create: `internal/agent/services/cloud_flusher.go`
- Create: `internal/agent/services/cloud_flusher_test.go`

The flusher reads from the segment files via `ReadFromCursor`, converts OTLP `LogRecord`s to cloud `LogEntry`s, and calls `WriteLogEntries`. It only flushes logs in this iteration; metrics and traces are buffered to disk but not yet uploaded.

- [ ] **Step 1: Write the failing tests**

Create `internal/agent/services/cloud_flusher_test.go`:

```go
package services

import (
	"context"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"

	cloudpb "github.com/wendylabsinc/wendy/proto/gen/cloudpb"
	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

// fakeRemoteLogging implements cloudpb.RemoteLoggingServiceClient for tests.
type fakeRemoteLogging struct {
	mu      sync.Mutex
	batches []*cloudpb.WriteLogEntriesRequest
	err     error // if non-nil, returned on next call then cleared
}

func (f *fakeRemoteLogging) WriteLogEntries(_ context.Context, req *cloudpb.WriteLogEntriesRequest, _ ...grpc.CallOption) (*cloudpb.WriteLogEntriesResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		err := f.err
		f.err = nil
		return nil, err
	}
	f.batches = append(f.batches, req)
	return &cloudpb.WriteLogEntriesResponse{AcceptedCount: int32(len(req.Entries))}, nil
}

func (f *fakeRemoteLogging) TailLogEntries(_ context.Context, _ *cloudpb.TailLogEntriesRequest, _ ...grpc.CallOption) (cloudpb.RemoteLoggingService_TailLogEntriesClient, error) {
	return nil, nil
}

func (f *fakeRemoteLogging) totalEntries() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	var n int
	for _, b := range f.batches {
		n += len(b.Entries)
	}
	return n
}

func TestCloudFlusher_FlushesEntries(t *testing.T) {
	buf, _ := makeTestBuffer(t, 10*1024*1024, 1*1024*1024)
	fake := &fakeRemoteLogging{}

	for i := 0; i < 5; i++ {
		buf.PublishLogs(makeLogReq("entry"))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	flusher := NewCloudFlusher(zap.NewNop(), buf, 1, 99)
	flusher.runOnce(ctx, fake, 0, 0)

	if fake.totalEntries() != 5 {
		t.Errorf("want 5 entries flushed to cloud, got %d", fake.totalEntries())
	}

	// Cursor must have advanced — re-running should send nothing.
	fake.batches = nil
	flusher.runOnce(ctx, fake, 0, 0)
	if fake.totalEntries() != 0 {
		t.Errorf("want 0 entries on second pass (cursor advanced), got %d", fake.totalEntries())
	}
}

func TestCloudFlusher_RetryOnError(t *testing.T) {
	buf, _ := makeTestBuffer(t, 10*1024*1024, 1*1024*1024)
	buf.PublishLogs(makeLogReq("entry"))

	fake := &fakeRemoteLogging{}
	fake.err = fmt.Errorf("transient")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	flusher := NewCloudFlusher(zap.NewNop(), buf, 1, 99)
	flusher.runOnce(ctx, fake, 0, 0)

	// First call errored, so cursor did not advance; batch list still empty.
	if fake.totalEntries() != 0 {
		t.Errorf("cursor must not advance on error: got %d entries", fake.totalEntries())
	}

	// Second attempt should succeed (error was cleared).
	flusher.runOnce(ctx, fake, 0, 0)
	if fake.totalEntries() != 1 {
		t.Errorf("want 1 entry on retry, got %d", fake.totalEntries())
	}
}
```

Note: add `"fmt"` to the import block.

- [ ] **Step 2: Run tests — expect failure**

```bash
go test ./internal/agent/services/... -run 'TestCloudFlusher' -v
```

Expected: compile error — `CloudFlusher`, `NewCloudFlusher`, `runOnce` not defined.

- [ ] **Step 3: Implement CloudFlusher**

Create `internal/agent/services/cloud_flusher.go`:

```go
package services

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/wendylabsinc/wendy/internal/agent/mtls"
	cloudpb "github.com/wendylabsinc/wendy/proto/gen/cloudpb"
	otelpb "github.com/wendylabsinc/wendy/proto/gen/otelpb"
)

const cloudFlusherBatchSize = 200

// CloudFlusher continuously reads log segments from TelemetryBuffer and
// uploads them to RemoteLoggingService. It only flushes logs; metrics and
// traces are buffered to disk but cloud upload is not yet implemented.
type CloudFlusher struct {
	logger          *zap.Logger
	buffer          *TelemetryBuffer
	provisioningSvc *ProvisioningService // nil in tests
	orgID           int32                // used in tests when provisioningSvc is nil
	assetID         int32                // used in tests when provisioningSvc is nil
}

// NewCloudFlusher creates a CloudFlusher. In production pass provisioningSvc;
// orgID and assetID are only used in tests (when provisioningSvc is nil).
func NewCloudFlusher(logger *zap.Logger, buffer *TelemetryBuffer, orgID, assetID int32) *CloudFlusher {
	return &CloudFlusher{
		logger:  logger,
		buffer:  buffer,
		orgID:   orgID,
		assetID: assetID,
	}
}

// NewCloudFlusherWithProvisioning creates a CloudFlusher for production use.
func NewCloudFlusherWithProvisioning(logger *zap.Logger, buffer *TelemetryBuffer, provisioningSvc *ProvisioningService) *CloudFlusher {
	return &CloudFlusher{logger: logger, buffer: buffer, provisioningSvc: provisioningSvc}
}

// Run blocks until ctx is cancelled. It waits for provisioning, dials the
// cloud, then continuously flushes buffered logs. It retries with backoff on
// any error.
func (f *CloudFlusher) Run(ctx context.Context) {
	backoff := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		cloudHost, orgID, assetID, enrolled := f.provisioningInfo()
		if !enrolled {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
			continue
		}

		certPEM, chainPEM, keyPEM := f.provisioningCerts()
		client, conn, err := f.dial(cloudHost, certPEM, chainPEM, keyPEM)
		if err != nil {
			f.logger.Warn("CloudFlusher: dial failed", zap.Error(err))
			f.sleep(ctx, backoff)
			backoff = min(backoff*2, 60*time.Second)
			continue
		}

		if err := f.flushLoop(ctx, client, orgID, assetID); err != nil && ctx.Err() == nil {
			f.logger.Warn("CloudFlusher: flush loop error, retrying", zap.Error(err))
		}
		conn.Close()
		if ctx.Err() != nil {
			return
		}
		f.sleep(ctx, backoff)
		backoff = min(backoff*2, 60*time.Second)
	}
}

func min(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func (f *CloudFlusher) provisioningInfo() (cloudHost string, orgID, assetID int32, enrolled bool) {
	if f.provisioningSvc != nil {
		return f.provisioningSvc.ProvisioningInfo()
	}
	return "", f.orgID, f.assetID, true
}

func (f *CloudFlusher) provisioningCerts() (certPEM, chainPEM, keyPEM string) {
	if f.provisioningSvc != nil {
		return f.provisioningSvc.ProvisioningCerts()
	}
	return "", "", ""
}

func (f *CloudFlusher) dial(cloudHost, certPEM, chainPEM, keyPEM string) (cloudpb.RemoteLoggingServiceClient, *grpc.ClientConn, error) {
	tlsCfg, err := mtls.NewTLSConfig(certPEM, chainPEM, keyPEM)
	if err != nil {
		return nil, nil, fmt.Errorf("building TLS config: %w", err)
	}
	conn, err := grpc.NewClient(cloudHost, grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))
	if err != nil {
		return nil, nil, fmt.Errorf("grpc dial: %w", err)
	}
	return cloudpb.NewRemoteLoggingServiceClient(conn), conn, nil
}

// flushLoop is the steady-state read-and-upload loop. It returns on context
// cancellation or on the first RPC error (caller retries with backoff).
func (f *CloudFlusher) flushLoop(ctx context.Context, client cloudpb.RemoteLoggingServiceClient, orgID, assetID int32) error {
	for {
		if err := f.runOnce(ctx, client, orgID, assetID); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// runOnce performs one read-from-cursor + upload pass.
// Exported only for test access (lowercase suffix would be unexported in test file).
func (f *CloudFlusher) runOnce(ctx context.Context, client cloudpb.RemoteLoggingServiceClient, orgID, assetID int32) error {
	cursor := f.buffer.LoadCursor(SignalLogs)
	msgs, next, err := f.buffer.ReadFromCursor(SignalLogs, cursor, cloudFlusherBatchSize)
	if err != nil {
		return fmt.Errorf("reading from buffer: %w", err)
	}
	if len(msgs) == 0 {
		return nil
	}

	entries := convertToLogEntries(msgs)
	if len(entries) == 0 {
		f.buffer.SaveCursor(SignalLogs, next) //nolint:errcheck
		return nil
	}

	// Group by app (service.name) and send one batch per app.
	grouped := groupEntriesByApp(msgs, entries)
	for appID, appEntries := range grouped {
		if _, err := client.WriteLogEntries(ctx, &cloudpb.WriteLogEntriesRequest{
			OrganizationId: orgID,
			AssetId:        assetID,
			AppId:          appID,
			Entries:        appEntries,
		}); err != nil {
			return fmt.Errorf("WriteLogEntries: %w", err)
		}
	}

	return f.buffer.SaveCursor(SignalLogs, next)
}

func (f *CloudFlusher) sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// convertToLogEntries converts OTLP ExportLogsServiceRequest messages to
// cloud LogEntry slices, preserving all resource/scope/record attributes.
func convertToLogEntries(msgs []proto.Message) []*cloudpb.LogEntry {
	var entries []*cloudpb.LogEntry
	for _, m := range msgs {
		req, ok := m.(*otelpb.ExportLogsServiceRequest)
		if !ok {
			continue
		}
		for _, rl := range req.GetResourceLogs() {
			resLabels := resourceLabels(rl.GetResource())
			for _, sl := range rl.GetScopeLogs() {
				for _, lr := range sl.GetLogRecords() {
					e := &cloudpb.LogEntry{
						Severity:   otelSeverityToCloud(lr.GetSeverityNumber()),
						LoggerName: resLabels["service.name"],
						Labels:     mergeLabels(resLabels, kvToMap(lr.GetAttributes())),
					}
					if lr.GetTimeUnixNano() > 0 {
						e.Timestamp = timestamppb.New(time.Unix(0, int64(lr.GetTimeUnixNano())))
					}
					if lr.GetObservedTimeUnixNano() > 0 {
						e.ObservedAt = timestamppb.New(time.Unix(0, int64(lr.GetObservedTimeUnixNano())))
					}
					if len(lr.GetTraceId()) > 0 {
						e.TraceId = hex.EncodeToString(lr.GetTraceId())
					}
					if len(lr.GetSpanId()) > 0 {
						e.SpanId = hex.EncodeToString(lr.GetSpanId())
					}
					if body := lr.GetBody(); body != nil {
						e.Payload = &cloudpb.LogEntry_TextPayload{TextPayload: anyValueString(body)}
					}
					entries = append(entries, e)
				}
			}
		}
	}
	return entries
}

// groupEntriesByApp returns a map from app/service name to its LogEntry slice.
// Entries without a service.name are grouped under "device".
func groupEntriesByApp(msgs []proto.Message, entries []*cloudpb.LogEntry) map[string][]*cloudpb.LogEntry {
	// Build an index: entry position → app name.
	var appNames []string
	for _, m := range msgs {
		req, ok := m.(*otelpb.ExportLogsServiceRequest)
		if !ok {
			continue
		}
		for _, rl := range req.GetResourceLogs() {
			app := resourceServiceName(rl.GetResource())
			if app == "" {
				app = "device"
			}
			for _, sl := range rl.GetScopeLogs() {
				for range sl.GetLogRecords() {
					appNames = append(appNames, app)
				}
			}
		}
	}
	result := make(map[string][]*cloudpb.LogEntry)
	for i, e := range entries {
		app := "device"
		if i < len(appNames) {
			app = appNames[i]
		}
		result[app] = append(result[app], e)
	}
	return result
}

func resourceLabels(res *otelpb.Resource) map[string]string {
	m := make(map[string]string)
	if res == nil {
		return m
	}
	for _, kv := range res.GetAttributes() {
		m[kv.GetKey()] = anyValueString(kv.GetValue())
	}
	return m
}

func kvToMap(kvs []*otelpb.KeyValue) map[string]string {
	m := make(map[string]string, len(kvs))
	for _, kv := range kvs {
		m[kv.GetKey()] = anyValueString(kv.GetValue())
	}
	return m
}

func mergeLabels(a, b map[string]string) map[string]string {
	out := make(map[string]string, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func otelSeverityToCloud(sev otelpb.SeverityNumber) cloudpb.LogSeverity {
	switch {
	case sev >= otelpb.SeverityNumber_SEVERITY_NUMBER_FATAL:
		return cloudpb.LogSeverity_LOG_SEVERITY_EMERGENCY
	case sev >= otelpb.SeverityNumber_SEVERITY_NUMBER_ERROR:
		return cloudpb.LogSeverity_LOG_SEVERITY_ERROR
	case sev >= otelpb.SeverityNumber_SEVERITY_NUMBER_WARN:
		return cloudpb.LogSeverity_LOG_SEVERITY_WARNING
	case sev >= otelpb.SeverityNumber_SEVERITY_NUMBER_INFO:
		return cloudpb.LogSeverity_LOG_SEVERITY_INFO
	default:
		return cloudpb.LogSeverity_LOG_SEVERITY_DEBUG
	}
}

```

Add `"google.golang.org/protobuf/proto"` to the import block (it is already used by `TelemetryBuffer`; add it here explicitly since `cloud_flusher.go` uses it via `convertToLogEntries`).

Note: `anyValueString` is defined in `device.go` in the CLI package but NOT in the services package. Add the following helper to `cloud_flusher.go` (or reuse the one in `telemetry_service.go` — check that it exists there; if not, add it):

```go
// anyValueString is already defined in telemetry_service.go within the services
// package — do NOT redefine it here. Remove the duplicate if present.
```

(The function `anyValueString` is defined in `internal/cli/commands/device.go`, not in `services`. You'll need to add it to `internal/agent/services/cloud_flusher.go` or a shared helpers file in the services package.)

Add to `cloud_flusher.go`:

```go
// otelAnyValueString converts an OTel AnyValue to its string representation.
// This mirrors the same helper in the CLI package but lives in the services package.
func otelAnyValueString(v *otelpb.AnyValue) string {
	if v == nil {
		return ""
	}
	switch vt := v.Value.(type) {
	case *otelpb.AnyValue_StringValue:
		return vt.StringValue
	case *otelpb.AnyValue_IntValue:
		return fmt.Sprintf("%d", vt.IntValue)
	case *otelpb.AnyValue_DoubleValue:
		return fmt.Sprintf("%g", vt.DoubleValue)
	case *otelpb.AnyValue_BoolValue:
		return fmt.Sprintf("%t", vt.BoolValue)
	default:
		return fmt.Sprintf("%v", v)
	}
}
```

And update `convertToLogEntries` to call `otelAnyValueString` instead of `anyValueString`.

- [ ] **Step 4: Run tests — expect pass**

```bash
go test ./internal/agent/services/... -run 'TestCloudFlusher' -v
```

Expected: both `TestCloudFlusher_*` tests pass.

- [ ] **Step 5: Full package test**

```bash
go test ./internal/agent/services/... -v
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add internal/agent/services/cloud_flusher.go internal/agent/services/cloud_flusher_test.go
git commit -m "feat: add CloudFlusher for continuous log upload to cloud"
```

---

### Task 8: Wire TelemetryBuffer into main.go and fix call sites

**Files:**
- Modify: `cmd/wendy-agent/main.go`

`TelemetryBuffer` replaces `TelemetryBroadcaster` as the entry point for all `Publish*` calls. The broadcaster still exists inside the buffer; only callers that currently call `broadcaster.Publish*` directly need updating.

- [ ] **Step 1: Identify all Publish call sites**

```bash
grep -rn 'broadcaster\.Publish\|Broadcaster()\.Publish' cmd/wendy-agent/ internal/agent/ \
     --include='*.go' | grep -v '_test.go'
```

The callers are:
- `OTELLogsReceiver.Export` → `broadcaster.PublishLogs`
- `OTELMetricsReceiver.Export` → `broadcaster.PublishMetrics`
- `OTELTraceReceiver.Export` → `broadcaster.PublishTraces`
- `OTELHTTPReceiver` → `broadcaster.PublishLogs/Metrics/Traces`
- `ContainerLogManager.publishToTelemetry` → `broadcaster.PublishLogs`
- `TelemetryCore.Write` → `broadcaster.PublishLogs`
- `CollectAgentMetrics` → `broadcaster.PublishMetrics`

Rather than threading `buffer` into every service, the cleanest approach is to construct the buffer wrapping the broadcaster, then replace the broadcaster reference in the OTEL receivers and the HTTP receiver. `ContainerLogManager`, `TelemetryCore`, and `CollectAgentMetrics` currently hold a `*TelemetryBroadcaster`; they switch to holding a pointer to an interface.

Define a small interface in `internal/agent/services/telemetry_buffer.go`:

```go
// TelemetryPublisher is the minimal interface for publishing OTel telemetry.
// Both *TelemetryBroadcaster and *TelemetryBuffer implement it.
type TelemetryPublisher interface {
	PublishLogs(req *otelpb.ExportLogsServiceRequest)
	PublishMetrics(req *otelpb.ExportMetricsServiceRequest)
	PublishTraces(req *otelpb.ExportTraceServiceRequest)
}

var _ TelemetryPublisher = (*TelemetryBroadcaster)(nil)
var _ TelemetryPublisher = (*TelemetryBuffer)(nil)
```

- [ ] **Step 2: Update ContainerLogManager, TelemetryCore, OTELHTTPReceiver, OTELReceivers, and CollectAgentMetrics to accept TelemetryPublisher**

In each of the following files, change the field type from `*TelemetryBroadcaster` to `TelemetryPublisher` and update the constructor signatures:

- `container_log_manager.go`: `broadcaster *TelemetryBroadcaster` → `broadcaster TelemetryPublisher`; update `NewContainerLogManager` signature.
- `telemetry_core.go`: `broadcaster *TelemetryBroadcaster` → `broadcaster TelemetryPublisher`; update `NewTelemetryCore` signature.
- `otel_http.go`: `broadcaster *TelemetryBroadcaster` → `broadcaster TelemetryPublisher`; update `NewOTELHTTPReceiver` signature.
- `telemetry_service.go`: `NewOTELLogsReceiver`, `NewOTELMetricsReceiver`, `NewOTELTraceReceiver` — change `b *TelemetryBroadcaster` to `b TelemetryPublisher`.
- `agent_metrics.go`: `CollectAgentMetrics(ctx, broadcaster *TelemetryBroadcaster)` → `CollectAgentMetrics(ctx context.Context, broadcaster TelemetryPublisher)`.

- [ ] **Step 3: Update main.go to construct TelemetryBuffer and pass it everywhere**

In `cmd/wendy-agent/main.go`, after the existing broadcaster construction:

```go
// existing:
broadcaster := services.NewTelemetryBroadcaster()

// add immediately after:
telemetryBuf, err := services.NewTelemetryBuffer(services.TelemetryBufferConfig{}, broadcaster, logger)
if err != nil {
    logger.Warn("telemetry disk buffer unavailable, falling back to in-memory only", zap.Error(err))
    // telemetryBuf is still usable — NewTelemetryBuffer never returns a nil buffer.
}
```

Then replace every use of `broadcaster` as a `TelemetryPublisher` argument with `telemetryBuf`:

```go
// Replace:
telemetryCore := services.NewTelemetryCore(broadcaster, zapcore.DebugLevel)
// With:
telemetryCore := services.NewTelemetryCore(telemetryBuf, zapcore.DebugLevel)

// Replace:
logManager := services.NewContainerLogManager(logger, broadcaster)
// With:
logManager := services.NewContainerLogManager(logger, telemetryBuf)

// Replace:
otelLogReceiver := services.NewOTELLogsReceiver(broadcaster)
otelMetricReceiver := services.NewOTELMetricsReceiver(broadcaster)
otelTraceReceiver := services.NewOTELTraceReceiver(broadcaster)
// With:
otelLogReceiver := services.NewOTELLogsReceiver(telemetryBuf)
otelMetricReceiver := services.NewOTELMetricsReceiver(telemetryBuf)
otelTraceReceiver := services.NewOTELTraceReceiver(telemetryBuf)
```

Pass `telemetryBuf` instead of `broadcaster` to `NewOTELHTTPReceiver` and `CollectAgentMetrics`.

Pass `telemetryBuf` as the `buffer` argument to `NewTelemetryService` and `NewTelemetryServiceV2`:

```go
telemetrySvc := services.NewTelemetryService(logger, broadcaster, telemetryBuf)
telemetrySvcV2 := services.NewTelemetryServiceV2(logger, broadcaster, telemetryBuf)
```

Start the CloudFlusher after the main gRPC servers are up (near the end of `main`):

```go
cloudFlusher := services.NewCloudFlusherWithProvisioning(logger, telemetryBuf, provisioningSvc)
wg.Add(1)
go func() {
    defer wg.Done()
    cloudFlusher.Run(ctx)
}()
```

- [ ] **Step 4: Build and verify**

```bash
go build ./...
```

Expected: clean compile.

```bash
go test ./... -count=1 -timeout 120s
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add cmd/wendy-agent/main.go \
        internal/agent/services/telemetry_buffer.go \
        internal/agent/services/container_log_manager.go \
        internal/agent/services/telemetry_core.go \
        internal/agent/services/otel_http.go \
        internal/agent/services/telemetry_service.go \
        internal/agent/services/agent_metrics.go
git commit -m "feat: wire TelemetryBuffer into agent and start CloudFlusher"
```

---

### Task 9: CLI `--tail` flag for `wendy device logs`

**Files:**
- Modify: `internal/cli/commands/device.go`

- [ ] **Step 1: Add the flag and wire it to the request**

In `newDeviceLogsCmd()` in `internal/cli/commands/device.go`:

Add the variable at the top of the function alongside the existing flag vars:

```go
var tail int32
```

Add the flag registration alongside the existing flags:

```go
cmd.Flags().Int32Var(&tail, "tail", 0, "Replay the last N log batches before streaming live (0 = live only)")
```

In the `RunE` body, set `last_n` on the request when `tail > 0`:

```go
req := &agentpb.StreamLogsRequest{}
if appName != "" {
    req.AppName = &appName
}
if serviceName != "" {
    req.ServiceName = &serviceName
}
if minSeverity > 0 {
    req.MinSeverity = &minSeverity
}
if tail > 0 {
    req.LastN = &tail
}
```

In the receive loop, print a separator between history and live records when `tail > 0`:

```go
for {
    resp, err := stream.Recv()
    if err == io.EOF {
        break
    }
    if err != nil {
        return fmt.Errorf("receiving logs: %w", err)
    }

    logs := resp.GetLogs()
    if logs == nil {
        continue
    }

    for _, rl := range logs.GetResourceLogs() {
        svcName := resourceServiceName(rl.GetResource())
        for _, sl := range rl.GetScopeLogs() {
            for _, lr := range sl.GetLogRecords() {
                if jsonOutput {
                    printLogRecordJSON(svcName, lr)
                } else {
                    printLogRecord(svcName, lr)
                }
            }
        }
    }

    // After history ends, print a visual separator.
    if tail > 0 && !resp.IsHistory {
        tail = 0 // only print once
        if !jsonOutput {
            fmt.Println(logMetaStyle.Render("── live ──────────────────────"))
        }
    }
}
```

- [ ] **Step 2: Build and smoke test**

```bash
go build ./cmd/wendy/...
```

Expected: clean compile.

Manual test (requires a running agent):

```bash
wendy device logs --tail 50
```

Expected: up to 50 recent log batches printed with dimmed separator, then live logs follow.

- [ ] **Step 3: Commit**

```bash
git add internal/cli/commands/device.go
git commit -m "feat: add --tail N flag to wendy device logs for history replay"
```

---

### Task 10: Final verification

- [ ] **Step 1: Full test suite**

```bash
go test ./... -count=1 -timeout 120s -race
```

Expected: all tests pass with race detector.

- [ ] **Step 2: Build all targets**

```bash
make build
```

Expected: all binaries build cleanly.

- [ ] **Step 3: Open pull request**

```bash
gh pr create \
  --title "feat: OTel disk buffer, history replay, and cloud flush" \
  --body "$(cat docs/superpowers/specs/2026-05-22-otel-disk-buffer-design.md)" \
  --base main
```
