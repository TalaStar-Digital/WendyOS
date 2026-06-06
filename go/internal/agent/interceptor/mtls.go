package interceptor

import (
	"context"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

func peerAddr(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return "unknown"
	}
	return p.Addr.String()
}

// CheckMTLS verifies that the gRPC context carries a mutually-authenticated TLS
// peer with at least one verified certificate chain. It logs and rejects calls
// that do not satisfy this requirement. Call this from RPC handlers that require
// explicit per-handler auth enforcement in addition to the server-level interceptor.
func CheckMTLS(ctx context.Context, logger *zap.Logger) error {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		logger.Warn("rejected unauthenticated gRPC caller", zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "missing peer credentials")
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok {
		logger.Warn("rejected non-TLS gRPC caller", zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "mTLS authentication required")
	}
	if len(tlsInfo.State.VerifiedChains) == 0 {
		logger.Warn("rejected caller with unverified certificate chain", zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "client certificate not verified")
	}
	return nil
}

// UnaryMTLSInterceptor rejects unary calls that do not carry verified mTLS peer credentials.
func UnaryMTLSInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		if err := CheckMTLS(ctx, logger); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// StreamMTLSInterceptor rejects streaming calls that do not carry verified mTLS peer credentials.
func StreamMTLSInterceptor(logger *zap.Logger) grpc.StreamServerInterceptor {
	return func(srv interface{}, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := CheckMTLS(ss.Context(), logger); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}
