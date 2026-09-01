package main

import (
	"testing"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

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
