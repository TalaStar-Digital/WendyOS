package services

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"

	otelpb "github.com/wendylabsinc/wendy/go/proto/gen/otelpb"
)

// SignalType identifies a telemetry signal kind.
type SignalType string

const (
	SignalLogs    SignalType = "logs"
	SignalMetrics SignalType = "metrics"
	SignalTraces  SignalType = "traces"
)

const maxSegmentFrameBytes = 1 * 1024 * 1024 // 1 MB per frame; single OTLP batch upper bound

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
	// maxReplayFrames caps last_n replay requests to prevent a malicious or
	// misconfigured client from driving unbounded disk reads per stream open.
	maxReplayFrames = 1000
)

// TelemetryBufferConfig configures TelemetryBuffer storage limits.
type TelemetryBufferConfig struct {
	Dir           string // defaults to $WENDY_TELEMETRY_DIR or /var/lib/wendy-agent/telemetry
	MaxTotalBytes int64  // defaults to 100 MB
	SegmentBytes  int64  // defaults to 4 MB
}

func (c *TelemetryBufferConfig) applyDefaults() {
	if c.Dir == "" {
		if d := os.Getenv("WENDY_TELEMETRY_DIR"); d != "" && filepath.IsAbs(d) {
			c.Dir = filepath.Clean(d)
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
	cursorMu    sync.Mutex // protects cursor.json read-modify-write
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

	if err := os.MkdirAll(cfg.Dir, 0700); err != nil {
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
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
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
		if err := w.f.Close(); err != nil {
			return fmt.Errorf("telemetry buffer: closing segment: %w", err)
		}
		seqNum = w.seqNum + 1
	}
	b.writers[sig] = nil // cleared so a subsequent open failure leaves a known state
	path := filepath.Join(b.cfg.Dir, segmentFilename(sig, seqNum))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
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
	if uint32(len(data)) > maxSegmentFrameBytes {
		b.logger.Warn("telemetry buffer: frame exceeds max size, dropping", zap.Int("size", len(data)))
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

	// Write header and payload in one syscall to prevent torn frames on crash.
	frame := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(data)))
	copy(frame[4:], data)
	if _, err := w.f.Write(frame); err != nil {
		b.logger.Warn("telemetry buffer: write frame failed", zap.Error(err))
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

const cursorFile = "cursor.json"

type cursorMap map[SignalType]flushCursor

// LoadCursor returns the persisted flush cursor for sig, or a zero cursor.
func (b *TelemetryBuffer) LoadCursor(sig SignalType) flushCursor {
	b.cursorMu.Lock()
	defer b.cursorMu.Unlock()
	data, err := os.ReadFile(filepath.Join(b.cfg.Dir, cursorFile))
	if err != nil {
		return flushCursor{}
	}
	var m cursorMap
	if err := json.Unmarshal(data, &m); err != nil {
		b.logger.Warn("telemetry buffer: corrupt cursor.json, resetting", zap.Error(err))
		return flushCursor{}
	}
	return m[sig]
}

// SaveCursor persists cursor for sig to cursor.json atomically.
func (b *TelemetryBuffer) SaveCursor(sig SignalType, cursor flushCursor) error {
	b.cursorMu.Lock()
	defer b.cursorMu.Unlock()
	path := filepath.Join(b.cfg.Dir, cursorFile)
	var m cursorMap
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &m); jerr != nil {
			b.logger.Warn("telemetry buffer: corrupt cursor.json on save, resetting", zap.Error(jerr))
		}
	}
	if m == nil {
		m = make(cursorMap)
	}
	m[sig] = cursor
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	// Use os.CreateTemp so concurrent callers write to distinct temp files.
	tmp, err := os.CreateTemp(b.cfg.Dir, "cursor-*.json.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() {
		tmp.Close()
		os.Remove(tmpPath) // no-op if rename succeeded
	}()
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

// ReadLastN returns up to n recent entries for sig in ascending time order.
// It reads segment files newest-to-oldest and prepends older frames.
// n is capped at maxReplayFrames to bound per-call disk I/O.
func (b *TelemetryBuffer) ReadLastN(sig SignalType, n int) []proto.Message {
	if n <= 0 {
		return nil
	}
	if n > maxReplayFrames {
		n = maxReplayFrames
	}
	segs, _ := listSegments(b.cfg.Dir, sig)
	var result []proto.Message
	for i := len(segs) - 1; i >= 0 && len(result) < n; i-- {
		// Read all frames in the segment so we can correctly take the trailing ones.
		frames, _, _ := readFramesFrom(filepath.Join(b.cfg.Dir, segs[i]), 0, sig, math.MaxInt32)
		need := n - len(result)
		if len(frames) > need {
			frames = frames[len(frames)-need:]
		}
		result = append(frames, result...) // prepend older frames to maintain ascending order
	}
	return result
}

// TelemetryPublisher is the minimal interface for publishing OTel telemetry.
// Both *TelemetryBroadcaster and *TelemetryBuffer implement it.
type TelemetryPublisher interface {
	PublishLogs(req *otelpb.ExportLogsServiceRequest)
	PublishMetrics(req *otelpb.ExportMetricsServiceRequest)
	PublishTraces(req *otelpb.ExportTraceServiceRequest)
}

var _ TelemetryPublisher = (*TelemetryBroadcaster)(nil)
var _ TelemetryPublisher = (*TelemetryBuffer)(nil)

// ReadFromCursor reads up to maxN frames starting at cursor for sig.
// Returns frames, the updated cursor, and any I/O error.
// If cursor.File is empty, reads from the oldest segment.
// If cursor.File was evicted, falls back to current oldest.
func (b *TelemetryBuffer) ReadFromCursor(sig SignalType, cursor flushCursor, maxN int) ([]proto.Message, flushCursor, error) {
	segs, err := listSegments(b.cfg.Dir, sig)
	if err != nil || len(segs) == 0 {
		return nil, cursor, err
	}

	startFile := cursor.File
	startOffset := cursor.Offset

	if startFile == "" {
		startFile = segs[0]
		startOffset = 0
	}

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
			// File exhausted — advance to next segment.
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
