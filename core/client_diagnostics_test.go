package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	coreAtomic "github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func clearClientDiagnosticEndpoints() {
	clientDiagnosticEndpoints.Store(&clientDiagnosticEndpointSet{hosts: map[string]map[uint16]struct{}{}})
}

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
	t.Cleanup(clearClientDiagnosticEndpoints)
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
	if got := sanitizeClientLogPayload("node.example.com:8443"); got != "[server-endpoint]" {
		t.Fatal("empty configuration removed protection for old connections")
	}
}

func TestClientDetailedLogPrivacyAcrossConfigurationAndDNS(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints(`proxies:
  - name: private-node-name
    server: secret-node.example
    port: 8443
    password: 'long-pass/with-secret'
    ws-opts:
      path: /private-transport
      headers:
        Host: secret-host.example
`)
	for _, payload := range []string{
		"dial secret-node.example:8443 using private-node-name failed: timeout",
		"password=long-pass/with-secret server=secret-node.example port=8443",
		"subscription https://subscription.example/private?token=secret failed",
		"TLS transport /private-transport Host secret-host.example long-pass%2Fwith-secret",
		"[DNS] secret-node.example --> CNAME secret-alias.example A 192.0.2.77 from 1.1.1.1",
	} {
		got := sanitizeClientLogPayload(payload)
		for _, secret := range []string{"secret-node.example", "8443", "private-node-name", "long-pass", "subscription.example", "secret-host.example", "/private-transport", "secret-alias.example", "192.0.2.77"} {
			if strings.Contains(got, secret) {
				t.Fatalf("private data retained in diagnostic output: %q", got)
			}
		}
	}
	ordinary := "[DNS] c2c.cdn.weixin.qq.com --> 203.0.113.9"
	if got := sanitizeClientLogPayload(ordinary); got != ordinary {
		t.Fatalf("ordinary DNS changed: %q", got)
	}
	setClientDiagnosticEndpoints("proxies: [{server: replacement.example, port: 443}]")
	if strings.Contains(sanitizeClientLogPayload("old connection secret-node.example:8443 timeout"), "8443") {
		t.Fatal("old connection endpoint leaked after refresh")
	}
}

func TestClientDiagnosticLateDNSRemainsProtectedAfterRefresh(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints("proxies: [{server: old.example, port: 8443}]")
	previous := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet)
	setClientDiagnosticEndpoints("proxies: [{server: new.example, port: 443}]")
	previous.recordAddresses("old.example", []netip.Addr{netip.MustParseAddr("192.0.2.91")})
	if strings.Contains(sanitizeClientLogPayload("dial 192.0.2.91:8443 timeout"), "192.0.2.91") {
		t.Fatal("late answer from previous configuration is unprotected")
	}
}

func TestClientDiagnosticURLHiddenBeforeTransportPathReplacement(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints("proxies: [{server: node.example, port: 443, ws-opts: {path: /}}]")
	got := sanitizeClientLogPayload("refresh https://subscription.example/private-link?token=secret failed")
	for _, secret := range []string{"subscription.example", "private-link", "secret"} {
		if strings.Contains(got, secret) {
			t.Fatal("transport path replacement exposed subscription URL")
		}
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

func (upstream *diagnosticTestResolver) Invalid() bool { return true }

func TestClientDiagnosticResolverObservesWithoutChangingLookupResults(t *testing.T) {
	setClientDiagnosticEndpoints("proxies: [{server: node.example.com, port: 8443}]")
	previous := resolver.ProxyServerHostResolver
	t.Cleanup(func() {
		resolver.ProxyServerHostResolver = previous
		clearClientDiagnosticEndpoints()
	})
	upstream := &diagnosticTestResolver{addresses: []netip.Addr{netip.MustParseAddr("192.0.2.20")}}
	resolver.ProxyServerHostResolver = upstream
	observeClientDiagnosticResolver()
	observeClientDiagnosticResolver()
	if resolver.ProxyServerHostResolver != upstream || upstream.lookups != 0 {
		t.Fatal("observer changed ownership or initiated a DNS lookup")
	}
	previousIPv6 := resolver.DisableIPv6
	resolver.DisableIPv6 = false
	t.Cleanup(func() { resolver.DisableIPv6 = previousIPv6 })
	for _, lookup := range []func(context.Context, string, resolver.Resolver) ([]netip.Addr, error){resolver.LookupIPWithResolver, resolver.LookupIPv4WithResolver, resolver.LookupIPv6WithResolver} {
		addresses, err := lookup(context.Background(), "node.example.com", upstream)
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
	if _, err := resolver.LookupIPWithResolver(context.Background(), "node.example.com", upstream); err != upstream.err {
		t.Fatal("observer changed DNS error")
	}
	resolver.ProxyServerHostResolver.ResetConnection()
	if upstream.resets != 1 {
		t.Fatal("observer prevented connection reset")
	}
}

func TestClientDiagnosticSystemDNSFallback(t *testing.T) {
	clearClientDiagnosticEndpoints()
	setClientDiagnosticEndpoints("proxies: [{server: system-node.example, port: 8443}]")
	previousSystem, previousProxy, previousIPv6 := resolver.SystemResolver, resolver.ProxyServerHostResolver, resolver.DisableIPv6
	t.Cleanup(func() {
		resolver.SystemResolver, resolver.ProxyServerHostResolver, resolver.DisableIPv6 = previousSystem, previousProxy, previousIPv6
		clearClientDiagnosticEndpoints()
	})
	upstream := &diagnosticTestResolver{addresses: []netip.Addr{netip.MustParseAddr("192.0.2.79")}}
	resolver.SystemResolver, resolver.ProxyServerHostResolver, resolver.DisableIPv6 = upstream, nil, false
	for _, lookup := range []func(context.Context, string, resolver.Resolver) ([]netip.Addr, error){resolver.LookupIPWithResolver, resolver.LookupIPv4WithResolver, resolver.LookupIPv6WithResolver} {
		addresses, err := lookup(context.Background(), "system-node.example", resolver.ProxyServerHostResolver)
		if err != nil || len(addresses) != 1 || addresses[0] != upstream.addresses[0] {
			t.Fatal("system lookup result changed")
		}
		if got := sanitizeClientLogPayload("dial tcp 192.0.2.79:8443: timeout"); got != "dial tcp [server-endpoint]: timeout" {
			t.Fatalf("system DNS endpoint leaked: %q", got)
		}
	}
	if upstream.lookups != 3 || resolver.SystemResolver != upstream || resolver.ProxyServerHostResolver != nil {
		t.Fatal("diagnostics changed DNS routing or lookup count")
	}
}

func TestClientDiagnosticProviderDefinitionsAndRefresh(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints(`proxy-providers:
  inline:
    type: inline
    payload:
      - name: inline-private-node
        type: http
        server: inline-node.example
        port: 8443
        password: inline-secret-value
`)
	for _, message := range []string{"dial inline-node.example:8443 timeout", "inline-private-node inline-secret-value"} {
		got := sanitizeClientLogPayload(message)
		if strings.Contains(got, "inline-") || strings.Contains(got, "8443") {
			t.Fatalf("inline provider definition leaked: %q", got)
		}
	}
	_, err := adapter.ParseProxy(map[string]any{
		"name": "refreshed-private-node", "type": "http", "server": "refreshed-node.example",
		"port": 9443, "password": "refreshed-secret-value",
	})
	if err != nil {
		t.Fatal(err)
	}
	setClientDiagnosticEndpoints("proxies: [{server: next-node.example, port: 443}]")
	got := sanitizeClientLogPayload("refreshed-private-node dial refreshed-node.example:9443 refreshed-secret-value")
	if strings.Contains(got, "refreshed-") || strings.Contains(got, "9443") {
		t.Fatalf("refreshed provider definition leaked: %q", got)
	}
}

func TestClientDiagnosticTrackerCopyProtectsAllOutputForms(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints("proxies: [{name: private-node, server: private-node.example, port: 8443}]")
	for _, lifecycle := range []string{"active", "closed"} {
		for _, serverDestination := range []bool{false, true} {
			source := &statistic.TrackerInfo{
				Start: time.Unix(1700000000, 0).UTC(), Metadata: &constant.Metadata{
					Host: "ordinary.example", DstIP: netip.MustParseAddr("203.0.113.17"), DstPort: 443,
					RemoteDst: "192.0.2.88", SpecialProxy: "private-node", SniffHost: "ordinary.example",
				},
				Chain: constant.Chain{"private-node", "private-group"}, ProviderChain: constant.Chain{"private-provider"},
				UploadTotal: coreAtomic.NewInt64(123), DownloadTotal: coreAtomic.NewInt64(456),
				Rule: "Domain", RulePayload: "private-node.example", Lifecycle: lifecycle, DurationMs: 42, EndReason: "timeout",
			}
			if serverDestination {
				source.Metadata.Host = "private-node.example"
				source.Metadata.DstPort = 8443
			}
			result := clientDiagnosticTracker(source)
			encoded, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			for _, secret := range []string{"192.0.2.88", "private-node", "private-group", "private-provider", "8443"} {
				if strings.Contains(string(encoded), secret) {
					t.Fatalf("tracker output leaked %q", secret)
				}
			}
			if result.UploadTotal.Load() != 123 || result.DownloadTotal.Load() != 456 || result.Lifecycle != lifecycle || result.DurationMs != 42 {
				t.Fatal("tracker statistics/lifecycle changed")
			}
			if serverDestination {
				if result.Metadata.Host != "" || result.Metadata.DstIP.IsValid() || result.Metadata.DstPort != 0 || result.Metadata.SniffHost != "" || result.DiagnosticDestination != "server-endpoint" {
					t.Fatal("server destination not hidden")
				}
			} else if result.Metadata.Host != "ordinary.example" || result.Metadata.DstIP != source.Metadata.DstIP || result.Metadata.DstPort != 443 {
				t.Fatal("ordinary destination hidden")
			}
			if source.Metadata.RemoteDst != "192.0.2.88" || source.Chain[0] != "private-node" || source.RulePayload != "private-node.example" {
				t.Fatal("live routing metadata changed")
			}
		}
	}
}

type diagnosticSnapshotTracker struct {
	statistic.Tracker
	info *statistic.TrackerInfo
}

func (tracker diagnosticSnapshotTracker) ID() string                   { return "diagnostic-snapshot-fixture" }
func (tracker diagnosticSnapshotTracker) Info() *statistic.TrackerInfo { return tracker.info }
func (tracker diagnosticSnapshotTracker) ReportLifecycle() bool        { return false }

func TestClientConnectionSnapshotRedactsBeforeSerialization(t *testing.T) {
	clearClientDiagnosticEndpoints()
	t.Cleanup(clearClientDiagnosticEndpoints)
	setClientDiagnosticEndpoints("proxies: [{server: snapshot-node.example, port: 18443}]")
	tracker := diagnosticSnapshotTracker{info: &statistic.TrackerInfo{
		Metadata: &constant.Metadata{Host: "snapshot-node.example", DstPort: 18443, RemoteDst: "192.0.2.31"},
		Chain:    constant.Chain{"private-snapshot-node"},
	}}
	statistic.DefaultManager.Join(tracker)
	t.Cleanup(func() { statistic.DefaultManager.Leave(tracker) })
	wire, err := json.Marshal(handleGetConnections())
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"snapshot-node.example", "18443", "192.0.2.31", "private-snapshot-node"} {
		if strings.Contains(string(wire), secret) {
			t.Fatalf("snapshot leaked %q", secret)
		}
	}
	if tracker.info.Metadata.Host != "snapshot-node.example" {
		t.Fatal("snapshot changed active connection")
	}
}

func TestClientDiagnosticServerEndpointsHideAllPorts(t *testing.T) {
	setClientDiagnosticEndpoints(`proxies:
  - server: 192.0.2.10
    port: 8443
    servername: node.example.com
  - server: ignored.example.com
    port: invalid
`)
	t.Cleanup(clearClientDiagnosticEndpoints)
	for _, test := range []struct {
		metadata constant.Metadata
		want     string
	}{
		{constant.Metadata{Host: "NODE.example.com.", DstPort: 8443}, "server-endpoint"},
		{constant.Metadata{Host: "node.example.com", DstPort: 443}, "server-endpoint"},
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
