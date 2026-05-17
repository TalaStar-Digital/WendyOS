package services

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentpbv2 "github.com/wendylabsinc/wendy/proto/gen/agentpb/v2"
)

type AgentUpdateService struct {
	agentpbv2.UnimplementedWendyAgentUpdateServiceServer
	logger     *zap.Logger
	updateMu   sync.Mutex
	isUpdating bool
}

func NewAgentUpdateService(logger *zap.Logger) *AgentUpdateService {
	return &AgentUpdateService{logger: logger}
}

func (s *AgentUpdateService) UpdateAgent(stream grpc.BidiStreamingServer[agentpbv2.UpdateAgentRequest, agentpbv2.UpdateAgentResponse]) error {
	s.updateMu.Lock()
	if s.isUpdating {
		s.updateMu.Unlock()
		return status.Error(codes.FailedPrecondition, "an update is already in progress")
	}
	s.isUpdating = true
	s.updateMu.Unlock()

	defer func() {
		s.updateMu.Lock()
		s.isUpdating = false
		s.updateMu.Unlock()
	}()

	s.logger.Info("UpdateAgent stream started")

	// Resolve paths before receiving chunks so we can stream directly to disk.
	execPath, err := os.Executable()
	if err != nil {
		return status.Errorf(codes.Internal, "failed to get executable path: %v", err)
	}
	execPath, err = filepath.EvalSymlinks(execPath)
	if err != nil {
		return status.Errorf(codes.Internal, "failed to resolve executable symlinks: %v", err)
	}
	info, err := os.Stat(execPath)
	if err != nil {
		return status.Errorf(codes.Internal, "failed to stat executable: %v", err)
	}
	originalPerm := info.Mode()

	tmpFile, err := os.CreateTemp(filepath.Dir(execPath), ".agent-update-*")
	if err != nil {
		return status.Errorf(codes.Internal, "failed to create update temp file: %v", err)
	}
	tmpPath := tmpFile.Name()
	if err := tmpFile.Chmod(originalPerm); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return status.Errorf(codes.Internal, "failed to set update file permissions: %v", err)
	}
	cleanupTmp := true
	fileClosed := false
	defer func() {
		if !fileClosed {
			if err := tmpFile.Close(); err != nil {
				s.logger.Warn("Failed to close update temp file during cleanup", zap.Error(err))
			}
		}
		if cleanupTmp {
			os.Remove(tmpPath)
		}
	}()

	hasher := sha256.New()

	for {
		msg, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return status.Errorf(codes.Internal, "error receiving update data: %v", err)
		}

		if chunk := msg.GetChunk(); chunk != nil {
			data := chunk.GetData()
			if _, err := tmpFile.Write(data); err != nil {
				return status.Errorf(codes.Internal, "failed to write update chunk: %v", err)
			}
			hasher.Write(data)
			continue
		}

		if ctrl := msg.GetControl(); ctrl != nil {
			if ctrl.GetUpdate() != nil {
				computedHash := hex.EncodeToString(hasher.Sum(nil))
				expectedHash := ctrl.GetUpdate().GetSha256()
				if expectedHash != "" && computedHash != expectedHash {
					return status.Errorf(codes.DataLoss,
						"SHA256 mismatch: expected %s, got %s", expectedHash, computedHash)
				}

				// Sync to disk before rename to prevent partial-write corruption on power loss.
				if err := tmpFile.Sync(); err != nil {
					return status.Errorf(codes.Internal, "failed to sync update file: %v", err)
				}
				if err := tmpFile.Close(); err != nil {
					return status.Errorf(codes.Internal, "failed to close update file: %v", err)
				}
				fileClosed = true

				backupPath := execPath + ".backup"
				if err := os.Rename(execPath, backupPath); err != nil {
					return status.Errorf(codes.Internal, "failed to create backup: %v", err)
				}

				if err := os.Rename(tmpPath, execPath); err != nil {
					if rbErr := os.Rename(backupPath, execPath); rbErr != nil {
						s.logger.Error("Failed to rollback from backup",
							zap.Error(rbErr),
							zap.String("backup_path", backupPath),
						)
					}
					return status.Errorf(codes.Internal, "failed to install update: %v", err)
				}
				cleanupTmp = false // renamed successfully, don't remove

				// fsync the directory so the rename is durable on power loss.
				if dir, err := os.Open(filepath.Dir(execPath)); err == nil {
					_ = dir.Sync()
					dir.Close()
				}

				info, _ := os.Stat(execPath)
				var size int64
				if info != nil {
					size = info.Size()
				}
				s.logger.Info("Agent binary updated successfully",
					zap.String("sha256", computedHash),
					zap.Int64("size", size),
				)

				if err := stream.Send(&agentpbv2.UpdateAgentResponse{
					ResponseType: &agentpbv2.UpdateAgentResponse_Updated_{
						Updated: &agentpbv2.UpdateAgentResponse_Updated{},
					},
				}); err != nil {
					return err
				}

				go func() {
					time.Sleep(500 * time.Millisecond)
					os.Exit(0)
				}()

				return nil
			}
		}
	}

	return status.Error(codes.InvalidArgument, "update stream ended without update control command")
}
