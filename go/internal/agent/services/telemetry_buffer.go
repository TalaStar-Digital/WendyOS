package services

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"go.uber.org/zap"
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

const maxSegmentFrameBytes = 10 * 1024 * 1024

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
// A partial frame or unmarshal error stops reading cleanly; no partial data is returned.
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
		// Allocate the destination proto first so we catch unknown signals before I/O.
		msg := newProtoForSignal(signal)
		if msg == nil {
			break
		}
		var hdr [4]byte
		if _, err := io.ReadFull(f, hdr[:]); err != nil {
			break
		}
		length := binary.BigEndian.Uint32(hdr[:])
		if length > maxSegmentFrameBytes {
			break
		}
		data := make([]byte, length)
		if _, err := io.ReadFull(f, data); err != nil {
			break
		}
		if err := proto.Unmarshal(data, msg); err != nil {
			break // corrupted frame — stop reading this file cleanly
		}
		msgs = append(msgs, msg)
		offset += int64(4 + length)
	}

	return msgs, offset, nil
}

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
// if needed. Falls back gracefully if the directory cannot be created.
func NewTelemetryBuffer(cfg TelemetryBufferConfig, broadcaster *TelemetryBroadcaster, logger *zap.Logger) (*TelemetryBuffer, error) {
	cfg.applyDefaults()

	b := &TelemetryBuffer{
		cfg:         cfg,
		broadcaster: broadcaster,
		logger:      logger,
		writers:     make(map[SignalType]*segWriter),
	}

	if err := os.MkdirAll(cfg.Dir, 0755); err != nil {
		logger.Warn("telemetry buffer: cannot create dir, disk writes disabled", zap.Error(err))
		return b, nil
	}

	b.evictIfNeeded()

	for _, sig := range []SignalType{SignalLogs, SignalMetrics, SignalTraces} {
		if err := b.openLatestWriter(sig); err != nil {
			return nil, fmt.Errorf("opening writer for %s: %w", sig, err)
		}
	}

	return b, nil
}

func (b *TelemetryBuffer) openLatestWriter(sig SignalType) error {
	segs, _ := listSegments(b.cfg.Dir, sig)
	seqNum := 1
	if len(segs) > 0 {
		last := segs[len(segs)-1]
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

func (b *TelemetryBuffer) rotateWriter(sig SignalType) error {
	w := b.writers[sig]
	seqNum := 1
	if w != nil {
		w.f.Close()
		seqNum = w.seqNum + 1
	}
	b.writers[sig] = nil // cleared so a subsequent open failure leaves a known state
	path := filepath.Join(b.cfg.Dir, segmentFilename(sig, seqNum))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	b.writers[sig] = &segWriter{f: f, size: 0, seqNum: seqNum}
	b.evictIfNeeded()
	return nil
}

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

func (b *TelemetryBuffer) findOldestSegment() string {
	var candidates []string
	for _, sig := range []SignalType{SignalLogs, SignalMetrics, SignalTraces} {
		segs, _ := listSegments(b.cfg.Dir, sig)
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
		if w == nil {
			return
		}
	}

	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(data)))
	if _, err := w.f.Write(hdr[:]); err != nil {
		b.logger.Warn("telemetry buffer: write header failed", zap.Error(err))
		// Force rotation so the orphan header is isolated in a sealed segment.
		b.rotateWriter(sig) //nolint:errcheck
		return
	}
	if _, err := w.f.Write(data); err != nil {
		b.logger.Warn("telemetry buffer: write payload failed", zap.Error(err))
		// Force rotation so the partial frame is isolated in a sealed segment.
		b.rotateWriter(sig) //nolint:errcheck
		return
	}
	w.size += needed
	b.evictIfNeeded()
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
