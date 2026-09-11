package main

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestClientLogRedactsServerHostsAndPorts(t *testing.T) {
	setClientDiagnosticEndpoints(`proxies:
  - server: node.example.com
    port: 8443
    sni: sni.example.com
  - server: 192.0.2.10
    port: 8443
  - server: '2001:db8::10'
    port: 8443
`)
	t.Cleanup(func() { setClientDiagnosticEndpoints("") })
	for _, address := range []string{
		"NODE.example.com.:8443", "node.example.com:443", "sni.example.com",
		"192.0.2.10:8443", "[2001:db8::10]:8443", "2001:db8::10",
		"[::ffff:192.0.2.10]:8443",
	} {
		payload := "[TCP] --> " + address + " using proxy: timeout"
		if got := sanitizeClientLogPayload(payload); got != "[TCP] --> [server-endpoint] using proxy: timeout" {
			t.Errorf("endpoint was not fully redacted: %q", got)
		}
	}
	for _, payload := range []string{
		"[TCP] --> example.com:443 using proxy",
		"[UDP] --> 192.0.2.11:8443 using direct",
		"[TCP] --> not-node.example.com:8443 using proxy",
	} {
		if got := sanitizeClientLogPayload(payload); got != payload {
			t.Errorf("ordinary destination changed: %q", got)
		}
	}
	setClientDiagnosticEndpoints("")
	if got := sanitizeClientLogPayload("node.example.com:8443"); got != "node.example.com:8443" {
		t.Fatal("endpoint index survived configuration replacement")
	}
}

type diagnosticTestResolver struct {
	resolver.Resolver
	addresses []netip.Addr
	err       error
	lookups   int
	resets    int
}

func (upstream *diagnosticTestResolver) LookupIP(context.Context, string) ([]netip.Addr, error) {
	upstream.lookups++
	return upstream.addresses, upstream.err
}

func (upstream *diagnosticTestResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	return upstream.LookupIP(ctx, host)
}

func (upstream *diagnosticTestResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	return upstream.LookupIP(ctx, host)
}

func (upstream *diagnosticTestResolver) ResetConnection() {
	upstream.resets++
}

func TestClientDiagnosticResolverObservesWithoutChangingLookupResults(t *testing.T) {
	setClientDiagnosticEndpoints("proxies: [{server: node.example.com, port: 8443}]")
	previous := resolver.ProxyServerHostResolver
	t.Cleanup(func() {
		resolver.ProxyServerHostResolver = previous
		setClientDiagnosticEndpoints("")
	})
	upstream := &diagnosticTestResolver{addresses: []netip.Addr{netip.MustParseAddr("192.0.2.20")}}
	resolver.ProxyServerHostResolver = upstream
	observeClientDiagnosticResolver()
	observeClientDiagnosticResolver()
	observer := resolver.ProxyServerHostResolver.(*clientDiagnosticResolver)
	if observer.Resolver != upstream || upstream.lookups != 0 {
		t.Fatal("observer changed ownership or initiated a DNS lookup")
	}
	for _, lookup := range []func(context.Context, string) ([]netip.Addr, error){observer.LookupIP, observer.LookupIPv4, observer.LookupIPv6} {
		addresses, err := lookup(context.Background(), "node.example.com")
		if err != nil || len(addresses) != 1 || addresses[0] != upstream.addresses[0] {
			t.Fatal("observer changed DNS answers")
		}
	}
	if upstream.lookups != 3 {
		t.Fatal("observer issued additional DNS lookups")
	}
	if clientDiagnosticDestination(&constant.Metadata{DstIP: upstream.addresses[0], DstPort: 8443}) != "server-endpoint" {
		t.Fatal("resolved node address is not classified")
	}
	if strings.Contains(sanitizeClientLogPayload("dial 192.0.2.20:8443: timeout"), "192.0.2.20") {
		t.Fatal("resolved node address leaked into a log")
	}
	upstream.err = errors.New("lookup failed")
	upstream.addresses = nil
	if _, err := observer.LookupIP(context.Background(), "node.example.com"); err != upstream.err {
		t.Fatal("observer changed DNS error")
	}
	observer.ResetConnection()
	if upstream.resets != 1 {
		t.Fatal("observer prevented connection reset")
	}
}

func TestClientDiagnosticServerEndpointMatchesArePortScoped(t *testing.T) {
	setClientDiagnosticEndpoints(`proxies:
  - server: 192.0.2.10
    port: 8443
    servername: node.example.com
  - server: ignored.example.com
    port: invalid
`)
	t.Cleanup(func() { setClientDiagnosticEndpoints("") })
	for _, test := range []struct {
		metadata constant.Metadata
		want     string
	}{
		{constant.Metadata{Host: "NODE.example.com.", DstPort: 8443}, "server-endpoint"},
		{constant.Metadata{Host: "node.example.com", DstPort: 443}, "destination"},
		{constant.Metadata{DstIP: netip.MustParseAddr("192.0.2.10"), DstPort: 8443}, "server-endpoint"},
		{constant.Metadata{Host: "example.com", DstPort: 8443}, "destination"},
	} {
		if got := clientDiagnosticDestination(&test.metadata); got != test.want {
			t.Fatalf("endpoint role = %q, want %q", got, test.want)
		}
	}
}

func TestClientTrackerDiagnosticsExposeOnlyFixedCategories(t *testing.T) {
	tests := []struct {
		name       string
		ruleType   string
		payload    string
		wantRule   string
		wantPolicy string
	}{
		{
			name:       "former httpdns domain is ordinary",
			ruleType:   "Domain",
			payload:    "dns.weixin.qq.com.cn",
			wantRule:   "domain",
			wantPolicy: "other",
		},
		{
			name:       "former httpdns cidr is ordinary",
			ruleType:   "IPCIDR",
			payload:    "119.29.29.98/31",
			wantRule:   "ip",
			wantPolicy: "other",
		},
		{
			name:       "overseas domain",
			ruleType:   "GeoSite",
			payload:    "geolocation-!cn",
			wantRule:   "domain",
			wantPolicy: "overseas-domain",
		},
		{
			name:       "mainland domain",
			ruleType:   "GeoSite",
			payload:    "CN",
			wantRule:   "domain",
			wantPolicy: "mainland-domain",
		},
		{
			name:       "mainland ip",
			ruleType:   "GeoIP",
			payload:    "CN",
			wantRule:   "ip",
			wantPolicy: "mainland-ip",
		},
		{
			name:       "private local value hidden",
			ruleType:   "DomainSuffix",
			payload:    "private-node.example",
			wantRule:   "domain",
			wantPolicy: "other",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			info := &statistic.TrackerInfo{
				Rule:        test.ruleType,
				RulePayload: test.payload,
			}
			annotateClientTrackerDiagnostics(info)
			if info.DiagnosticRule != test.wantRule {
				t.Fatalf("DiagnosticRule = %q, want %q", info.DiagnosticRule, test.wantRule)
			}
			if info.DiagnosticPolicy != test.wantPolicy {
				t.Fatalf("DiagnosticPolicy = %q, want %q", info.DiagnosticPolicy, test.wantPolicy)
			}
			if info.DiagnosticPolicy == test.payload {
				t.Fatalf("raw rule payload leaked into diagnostic policy: %q", info.DiagnosticPolicy)
			}
		})
	}
	for _, geosite := range clientReturnGeoSites {
		t.Run("return "+geosite, func(t *testing.T) {
			info := &statistic.TrackerInfo{
				Rule:        "GeoSite",
				RulePayload: geosite,
			}
			annotateClientTrackerDiagnostics(info)
			if info.DiagnosticRule != "domain" || info.DiagnosticPolicy != "mainland-domain" {
				t.Fatalf("return geosite diagnostics = %q/%q", info.DiagnosticRule, info.DiagnosticPolicy)
			}
		})
	}
}

func TestClientDiagnosticRouteUsesOnlyFixedCategories(t *testing.T) {
	tests := []struct {
		name  string
		chain []string
		want  string
	}{
		{name: "unknown", want: "unknown"},
		{name: "proxy", chain: []string{"Private-Node"}, want: "proxy"},
		{name: "direct", chain: []string{"Private-Node", "DIRECT"}, want: "direct"},
		{name: "reject", chain: []string{"REJECT"}, want: "reject"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := clientDiagnosticRoute(test.chain); got != test.want {
				t.Fatalf("clientDiagnosticRoute() = %q, want %q", got, test.want)
			}
		})
	}
}
