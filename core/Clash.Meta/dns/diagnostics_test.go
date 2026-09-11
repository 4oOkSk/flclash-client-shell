package dns

import (
	"context"
	"testing"

	icontext "github.com/metacubex/mihomo/context"
	D "github.com/miekg/dns"
)

func TestServiceDiagnosticsIncludeSilentFailures(t *testing.T) {
	before := GetServiceDiagnostics()
	query := new(D.Msg).SetQuestion("example.com.", D.TypeA)
	for _, rcode := range []int{D.RcodeSuccess, D.RcodeNameError, D.RcodeServerFailure, -1} {
		service := &Service{handler: func(_ *icontext.DNSContext, request *D.Msg) (*D.Msg, error) {
			if rcode == -1 {
				return nil, context.DeadlineExceeded
			}
			return new(D.Msg).SetRcode(request, rcode), nil
		}}
		_, _ = service.ServeMsg(context.Background(), query)
	}
	after := GetServiceDiagnostics()
	if after.Completed-before.Completed != 4 || after.Failed-before.Failed != 2 || after.Timeouts-before.Timeouts != 1 || after.LastFailureAt == 0 {
		t.Fatalf("DNS service diagnostic delta: before=%+v after=%+v", before, after)
	}
}
