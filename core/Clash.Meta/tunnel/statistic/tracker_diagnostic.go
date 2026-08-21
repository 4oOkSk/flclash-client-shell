package statistic

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
	C "github.com/metacubex/mihomo/constant"
)

type trackerLifecycle struct {
	closeOnce sync.Once
	closeErr  error
	mu        sync.Mutex
	reason    string
	duration  int64
}

func (l *trackerLifecycle) recordEnd(err error) {
	reason := classifyTrackerEndReason(err)
	if reason == "" {
		return
	}
	l.mu.Lock()
	if trackerEndReasonPriority(reason) > trackerEndReasonPriority(l.reason) {
		l.reason = reason
	}
	l.mu.Unlock()
}

// recordIdleTimeout is deliberately separate from generic network timeouts.
// The tunnel owns the UDP read deadline that calls this method, so an expiry is
// normal session reclamation rather than evidence of a failed route.
func (l *trackerLifecycle) recordIdleTimeout() {
	l.mu.Lock()
	if trackerEndReasonPriority(l.reason) <= trackerEndReasonPriority("timeout") {
		l.reason = "idle-timeout"
	}
	l.mu.Unlock()
}

func (l *trackerLifecycle) finalize(start time.Time, upload, download int64) {
	l.mu.Lock()
	l.duration = trackerDurationMs(start)
	l.reason = finalizeTrackerEndReason(l.reason, upload, download)
	l.mu.Unlock()
}

func (l *trackerLifecycle) snapshot(source *TrackerInfo) *TrackerInfo {
	l.mu.Lock()
	defer l.mu.Unlock()
	return trackerInfoSnapshot(source, "closed", l.duration, l.reason)
}

func classifyTrackerEndReason(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, syscall.ETIMEDOUT) {
		return "timeout"
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "timeout"
	}
	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refused"
	case errors.Is(err, syscall.EHOSTUNREACH), errors.Is(err, syscall.ENETUNREACH):
		return "unreachable"
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.ECONNABORTED), errors.Is(err, syscall.EPIPE):
		return "reset"
	case errors.Is(err, io.EOF):
		return "eof"
	case errors.Is(err, net.ErrClosed):
		return "closed"
	default:
		return "io-error"
	}
}

func trackerEndReasonPriority(reason string) int {
	switch reason {
	case "refused", "unreachable", "reset":
		return 5
	case "io-error":
		return 4
	case "idle-timeout":
		return 3
	case "timeout":
		return 2
	case "eof", "closed":
		return 1
	default:
		return 0
	}
}

func finalizeTrackerEndReason(reason string, upload, download int64) string {
	if reason == "idle-timeout" {
		return reason
	}
	if trackerEndReasonPriority(reason) >= 2 {
		return reason
	}
	if upload > 0 && download == 0 {
		return "no-response"
	}
	if upload == 0 && download == 0 {
		return "idle"
	}
	if reason == "eof" {
		return "eof"
	}
	return "closed"
}

func trackerDurationMs(start time.Time) int64 {
	duration := time.Since(start).Milliseconds()
	if duration < 0 {
		return 0
	}
	return duration
}

func trackerInfoSnapshot(source *TrackerInfo, lifecycle string, durationMs int64, endReason string) *TrackerInfo {
	var metadata *C.Metadata
	if source.Metadata != nil {
		metadata = source.Metadata.Clone()
		metadata.SrcGeoIP = append([]string(nil), source.Metadata.SrcGeoIP...)
		metadata.DstGeoIP = append([]string(nil), source.Metadata.DstGeoIP...)
	}
	return &TrackerInfo{
		UUID:             source.UUID,
		Metadata:         metadata,
		UploadTotal:      atomic.NewInt64(source.UploadTotal.Load()),
		DownloadTotal:    atomic.NewInt64(source.DownloadTotal.Load()),
		Start:            source.Start,
		Chain:            append(C.Chain(nil), source.Chain...),
		ProviderChain:    append(C.Chain(nil), source.ProviderChain...),
		Rule:             source.Rule,
		RulePayload:      source.RulePayload,
		Lifecycle:        lifecycle,
		DurationMs:       durationMs,
		EndReason:        endReason,
		DiagnosticRoute:  source.DiagnosticRoute,
		DiagnosticRule:   source.DiagnosticRule,
		DiagnosticPolicy: source.DiagnosticPolicy,
	}
}
