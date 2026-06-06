package interceptor

import (
	"context"
	"crypto/x509"

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
//
// Certificate revocation is handled at the TLS layer by the VerifyPeerCertificate
// hook in mtls.NewTLSConfig: it enforces a maximum certificate lifetime (25 h) as
// a compensating control, ensuring compromised credentials expire within one day.
// By the time this function runs the handshake has already applied that policy,
// so no duplicate revocation check is needed here.
//
// Audit logging: the certificate serial number (not PII) is logged at Debug level.
// Subject CN is intentionally omitted from per-call logs to satisfy data-minimisation
// requirements — it may contain a username or device identifier.
func CheckMTLS(ctx context.Context, logger *zap.Logger) error {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		logger.Warn("rejected unauthenticated gRPC caller",
			zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "missing peer credentials")
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok {
		logger.Warn("rejected non-TLS gRPC caller",
			zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "mTLS authentication required")
	}
	if len(tlsInfo.State.VerifiedChains) == 0 {
		logger.Warn("rejected caller with unverified certificate chain",
			zap.String("remote", peerAddr(ctx)))
		return status.Errorf(codes.Unauthenticated, "client certificate not verified")
	}
	leaf := tlsInfo.State.VerifiedChains[0][0]
	// Defence-in-depth EKU check: verify the leaf asserts clientAuth (or carries no
	// EKU restriction, which permits all uses). The VerifyPeerCertificate hook in
	// mtls.NewTLSConfig already enforces this during the handshake, but re-checking
	// here ensures the constraint holds even if that hook is absent or the TLS config
	// is replaced without updating the server options.
	if len(leaf.ExtKeyUsage) > 0 {
		hasClientAuth := false
		for _, eku := range leaf.ExtKeyUsage {
			if eku == x509.ExtKeyUsageClientAuth {
				hasClientAuth = true
				break
			}
		}
		if !hasClientAuth {
			logger.Warn("rejected cert without clientAuth EKU",
				zap.String("remote", peerAddr(ctx)),
				zap.String("serial", leaf.SerialNumber.String()))
			return status.Errorf(codes.Unauthenticated, "certificate is not valid for client authentication")
		}
	}
	// Log the serial number (not PII) at Debug level for per-call audit correlation.
	// Subject CN is omitted: it may contain a username or device identifier, logging
	// it on every call creates a high-volume PII stream that conflicts with
	// data-minimisation requirements.
	logger.Debug("mTLS peer authenticated",
		zap.String("remote", peerAddr(ctx)),
		zap.String("serial", leaf.SerialNumber.String()),
	)
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
