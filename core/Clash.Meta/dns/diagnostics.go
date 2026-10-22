package dns

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"time"

	D "github.com/miekg/dns"
)

type ServiceDiagnostics struct {
	Completed     uint64 `json:"completed"`
	Failed        uint64 `json:"failed"`
	Timeouts      uint64 `json:"timeouts"`
	LastFailureAt int64  `json:"last_failure_at"`
}

var serviceCompleted atomic.Uint64
var serviceFailed atomic.Uint64
var serviceTimeouts atomic.Uint64
var serviceLastFailureAt atomic.Int64

func GetServiceDiagnostics() ServiceDiagnostics {
	return ServiceDiagnostics{
		Completed:     serviceCompleted.Load(),
		Failed:        serviceFailed.Load(),
		Timeouts:      serviceTimeouts.Load(),
		LastFailureAt: serviceLastFailureAt.Load(),
	}
}

func recordServiceResult(response *D.Msg, err error) {
	serviceCompleted.Add(1)
	if err == nil && response != nil && response.Rcode != D.RcodeServerFailure {
		return
	}
	serviceFailed.Add(1)
	serviceLastFailureAt.Store(time.Now().Unix())
	var networkError net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.As(err, &networkError) && networkError.Timeout() {
		serviceTimeouts.Add(1)
	}
}
