package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	commonYaml "github.com/metacubex/mihomo/common/yaml"
)

const clientRouteTestConfig = `
mixed-port: 7890
profile:
  store-selected: true
  store-fake-ip: true
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - geosite:cn
  default-nameserver:
    - 223.5.5.5
  nameserver:
    - https://223.5.5.5/dns-query
  fallback:
    - https://1.1.1.1/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
  nameserver-policy:
    geosite:cn:
      - https://223.5.5.5/dns-query
proxies:
  - name: hidden-node
    type: socks5
    server: 192.0.2.10
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Auto
      - hidden-node
      - DIRECT
  - name: Auto
    type: url-test
    proxies:
      - hidden-node
rules:
  - DOMAIN-SUFFIX,example.cn,DIRECT
  - MATCH,Proxy
`

func TestApplyClientRouteOverlay(t *testing.T) {
	overlay := &ClientRouteOverlay{
		Rules: []string{
			"DOMAIN-SUFFIX,example.com,Proxy",
			"IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
			"PROCESS-NAME,example.exe,REJECT",
			"RULE-SET,ads,REJECT",
			"DOMAIN,placeholder.example,MATCH",
		},
		RuleProviders: map[string]ClientRuleProviderConfig{
			"ads": {
				URL:      "https://example.com/ads.mrs",
				Behavior: "domain",
				Format:   "mrs",
				Interval: 86400,
			},
		},
	}
	merged, err := applyClientRouteOverlay(clientRouteTestConfig, overlay)
	if err != nil {
		t.Fatalf("applyClientRouteOverlay() error = %v", err)
	}
	var view clientRouteConfigView
	if err := commonYaml.Unmarshal([]byte(merged), &view); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	if len(view.Rules) != 7 {
		t.Fatalf("rules length = %d, want 7", len(view.Rules))
	}
	if got := view.Rules[0]; got != "DOMAIN-SUFFIX,example.com,Proxy" {
		t.Fatalf("first rule = %q", got)
	}
	if got := view.Rules[4]; got != "DOMAIN,placeholder.example,Proxy" {
		t.Fatalf("MATCH placeholder rule = %q", got)
	}
	if got := view.Rules[5]; got != "DOMAIN-SUFFIX,example.cn,DIRECT" {
		t.Fatalf("base rule order changed: %q", got)
	}
	if len(view.RuleProviders) != 1 {
		t.Fatalf("rule providers length = %d, want 1", len(view.RuleProviders))
	}
	for name, provider := range view.RuleProviders {
		if !strings.HasPrefix(name, "__neutralvendor_local_") {
			t.Fatalf("internal provider name = %q", name)
		}
		if provider["type"] != "http" || provider["behavior"] != "domain" {
			t.Fatalf("provider = %#v", provider)
		}
		if !strings.Contains(view.Rules[3], name) {
			t.Fatalf("RULE-SET did not use internal provider: %q", view.Rules[3])
		}
	}
	if !strings.Contains(merged, "192.0.2.10") {
		t.Fatal("base proxy was lost while merging overlay")
	}
}

func TestApplyClientRouteOverlayRejectsProxyTarget(t *testing.T) {
	_, err := applyClientRouteOverlay(clientRouteTestConfig, &ClientRouteOverlay{
		Rules: []string{"DOMAIN,example.com,hidden-node"},
	})
	if err == nil || err.Error() != "invalid rule target" {
		t.Fatalf("error = %v, want invalid rule target", err)
	}
}

func TestApplyClientRouteOverlayRejectsUnsafeProvider(t *testing.T) {
	_, err := applyClientRouteOverlay(clientRouteTestConfig, &ClientRouteOverlay{
		Rules: []string{"RULE-SET,local,DIRECT"},
		RuleProviders: map[string]ClientRuleProviderConfig{
			"local": {
				URL:      "file:///etc/passwd",
				Behavior: "classical",
				Format:   "text",
				Interval: 86400,
			},
		},
	})
	if err == nil || err.Error() != "invalid rule provider URL" {
		t.Fatalf("error = %v, want invalid rule provider URL", err)
	}
}

func TestApplyClientRouteOverlayRejectsClassicalMRSProvider(t *testing.T) {
	_, err := applyClientRouteOverlay(clientRouteTestConfig, &ClientRouteOverlay{
		Rules: []string{"RULE-SET,local,DIRECT"},
		RuleProviders: map[string]ClientRuleProviderConfig{
			"local": {
				URL:      "https://example.com/rules.mrs",
				Behavior: "classical",
				Format:   "mrs",
				Interval: 86400,
			},
		},
	})
	if err == nil || err.Error() != "mrs rule provider must use domain or ipcidr behavior" {
		t.Fatalf("error = %v, want mrs behavior error", err)
	}
}

func TestApplyClientRouteOverlayLeavesEmptyOverlayUntouched(t *testing.T) {
	merged, err := applyClientRouteOverlay(
		clientRouteTestConfig,
		&ClientRouteOverlay{},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	if merged != clientRouteTestConfig {
		t.Fatal("empty overlay changed the base config")
	}
}

func TestApplyClientRouteOverlayBuildsManagedRouting(t *testing.T) {
	merged, err := applyClientRouteOverlay(
		clientRouteTestConfig,
		&ClientRouteOverlay{
			Rules: []string{"DOMAIN,local.example,DIRECT"},
			Managed: &ClientManagedRouting{
				Mode:       clientManagedRouteBypassMainland,
				RejectIPv6: true,
			},
		},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	var document map[string]any
	if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	var view clientRouteConfigView
	if err := commonYaml.Unmarshal([]byte(merged), &view); err != nil {
		t.Fatalf("merged YAML view error = %v", err)
	}
	wantRules := append(
		[]string{"DOMAIN,local.example,DIRECT"},
		buildClientManagedRules(
			clientManagedServerGroup,
			&ClientManagedRouting{
				Mode:       clientManagedRouteBypassMainland,
				RejectIPv6: true,
			},
		)...,
	)
	if strings.Join(view.Rules, "\n") != strings.Join(wantRules, "\n") {
		t.Fatalf("managed rules = %#v", view.Rules)
	}
	if document["mode"] != "rule" || document["allow-lan"] != false {
		t.Fatalf("managed general config = %#v", document)
	}
	if document["geo-auto-update"] != true || document["geo-update-interval"] != 168 {
		t.Fatalf("managed geodata update = %#v", document)
	}
	geoXURL, ok := document["geox-url"].(map[string]any)
	if !ok || geoXURL["geoip"] != clientGeoIPURL || geoXURL["geosite"] != clientGeoSiteURL {
		t.Fatalf("managed geox-url = %#v", document["geox-url"])
	}
	if _, exists := document["rule-providers"]; exists {
		t.Fatal("unused server rule providers survived managed config")
	}
	dns, ok := document["dns"].(map[string]any)
	if !ok {
		t.Fatalf("managed dns = %#v", document["dns"])
	}
	if dns["enable"] != true || dns["ipv6"] != false || dns["enhanced-mode"] != "redir-host" || dns["respect-rules"] != true {
		t.Fatalf("managed dns mode = %#v", dns)
	}
	wantNameServers := []string{
		clientOtherDNS,
	}
	if got := anyStrings(dns["nameserver"].([]any)); strings.Join(got, "\x00") != strings.Join(wantNameServers, "\x00") {
		t.Fatalf("managed nameservers = %#v", got)
	}
	if got := anyStrings(dns["proxy-server-nameserver"].([]any)); strings.Join(got, "\x00") != "223.5.5.5\x00119.29.29.29" {
		t.Fatalf("managed proxy bootstrap dns = %#v", got)
	}
	nameServerPolicy, ok := dns["nameserver-policy"].(map[string]any)
	if !ok {
		t.Fatalf("managed nameserver policy = %#v", dns["nameserver-policy"])
	}
	if got := anyStrings(nameServerPolicy[clientMainlandDNSPolicy].([]any)); strings.Join(got, "\x00") != clientMainlandDNS {
		t.Fatalf("managed mainland nameservers = %#v", got)
	}
	for _, removed := range []string{
		"fallback", "fallback-filter", "fake-ip-range", "fake-ip-filter",
	} {
		if _, exists := dns[removed]; exists {
			t.Fatalf("managed dns retained %s: %#v", removed, dns[removed])
		}
	}
	profile, ok := document["profile"].(map[string]any)
	if !ok || profile["store-fake-ip"] != false {
		t.Fatalf("managed profile retained fake IP persistence: %#v", document["profile"])
	}
	sniffer, ok := document["sniffer"].(map[string]any)
	if !ok || sniffer["enable"] != true || sniffer["override-destination"] != true ||
		sniffer["force-dns-mapping"] != true || sniffer["parse-pure-ip"] != true {
		t.Fatalf("managed split sniffer = %#v", document["sniffer"])
	}
	sniff, ok := sniffer["sniff"].(map[string]any)
	if !ok {
		t.Fatalf("managed split protocols = %#v", sniffer["sniff"])
	}
	for _, protocol := range []string{"HTTP", "TLS", "QUIC"} {
		config, ok := sniff[protocol].(map[string]any)
		if !ok || strings.Join(anyStrings(config["ports"].([]any)), "\x00") != "1-65535" {
			t.Fatalf("managed split %s sniffer = %#v", protocol, sniff[protocol])
		}
	}
	if !strings.Contains(merged, "192.0.2.10") {
		t.Fatal("base proxy was lost")
	}
	groups, ok := document["proxy-groups"].([]any)
	if !ok || len(groups) != 3 {
		t.Fatalf("proxy groups = %#v", document["proxy-groups"])
	}
	group, _ := groups[2].(map[string]any)
	if group["name"] != clientManagedServerGroup || group["type"] != "select" {
		t.Fatalf("managed server group = %#v", group)
	}
	proxies, _ := group["proxies"].([]any)
	if len(proxies) != 2 || fmt.Sprint(proxies[0]) != "Auto" || fmt.Sprint(proxies[1]) != "hidden-node" {
		t.Fatalf("managed server members = %#v", proxies)
	}
	if strings.Contains(strings.Join(anyStrings(proxies), "\n"), "DIRECT") {
		t.Fatalf("DIRECT survived server selection: %#v", proxies)
	}
}

func TestManagedDNSUsesSplitTCPResolversAndFollowsIPRules(t *testing.T) {
	wantNameServers := []string{clientOtherDNS}
	for _, mode := range []ClientManagedRouteMode{
		clientManagedRouteGlobal,
		clientManagedRouteBypassMainland,
		clientManagedRouteBypassOverseas,
		clientManagedRouteDirectAllLegacy,
	} {
		routing := ClientManagedRouting{Mode: mode}
		merged, err := applyClientRouteOverlay(
			clientRouteTestConfig,
			&ClientRouteOverlay{Managed: &routing},
		)
		if err != nil {
			t.Fatalf("routing %#v: error = %v", routing, err)
		}
		var document map[string]any
		if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
			t.Fatalf("routing %#v: merged YAML error = %v", routing, err)
		}
		dns, ok := document["dns"].(map[string]any)
		if !ok {
			t.Fatalf("routing %#v: managed dns = %#v", routing, document["dns"])
		}
		got := anyStrings(dns["nameserver"].([]any))
		if strings.Join(got, "\x00") != strings.Join(wantNameServers, "\x00") {
			t.Fatalf("routing %#v: managed nameservers = %#v, want %#v", routing, got, wantNameServers)
		}
		for _, nameserver := range got {
			if strings.Contains(nameserver, "#") {
				t.Fatalf("routing %#v: destination DNS is pinned to an exit: %q", routing, nameserver)
			}
		}
		if dns["respect-rules"] != true || dns["enhanced-mode"] != "redir-host" {
			t.Fatalf("routing %#v: managed DNS routing mode = %#v", routing, dns)
		}
		policy, ok := dns["nameserver-policy"].(map[string]any)
		wantPolicySize := 1
		if mode == clientManagedRouteBypassOverseas {
			wantPolicySize += len(clientReturnGeoSites)
		}
		if !ok || len(policy) != wantPolicySize {
			t.Fatalf("routing %#v: mainland DNS policy = %#v", routing, dns["nameserver-policy"])
		}
		if got := anyStrings(policy[clientMainlandDNSPolicy].([]any)); strings.Join(got, "\x00") != clientMainlandDNS {
			t.Fatalf("routing %#v: mainland nameserver = %#v", routing, got)
		}
		for _, geosite := range clientReturnGeoSites {
			key := "geosite:" + geosite
			value, exists := policy[key]
			if mode != clientManagedRouteBypassOverseas {
				if exists {
					t.Fatalf("routing %#v: unexpected return DNS policy %q", routing, key)
				}
				continue
			}
			if !exists || strings.Join(anyStrings(value.([]any)), "\x00") != clientMainlandDNS {
				t.Fatalf("routing %#v: return nameserver %q = %#v", routing, key, value)
			}
		}
	}
}

func TestManagedGlobalModesPreserveBaseSniffer(t *testing.T) {
	configYAML := clientRouteTestConfig + `
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [8443]
  skip-domain:
    - +.push.apple.com
`
	for _, mode := range []ClientManagedRouteMode{
		clientManagedRouteGlobal,
		clientManagedRouteDirectAllLegacy,
	} {
		merged, err := applyClientRouteOverlay(
			configYAML,
			&ClientRouteOverlay{Managed: &ClientManagedRouting{Mode: mode}},
		)
		if err != nil {
			t.Fatalf("mode %s: error = %v", mode, err)
		}
		var document map[string]any
		if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
			t.Fatalf("mode %s: merged YAML error = %v", mode, err)
		}
		sniffer, _ := document["sniffer"].(map[string]any)
		sniff, _ := sniffer["sniff"].(map[string]any)
		if len(sniff) != 1 {
			t.Fatalf("mode %s changed sniffer protocols: %#v", mode, sniff)
		}
		tls, _ := sniff["TLS"].(map[string]any)
		if strings.Join(anyStrings(tls["ports"].([]any)), "\x00") != "8443" {
			t.Fatalf("mode %s changed TLS ports: %#v", mode, tls)
		}
		if got := anyStrings(sniffer["skip-domain"].([]any)); strings.Join(got, "\x00") != "+.push.apple.com" {
			t.Fatalf("mode %s changed skip-domain: %#v", mode, got)
		}
	}
}

func TestManagedSplitModesPreserveSnifferExclusions(t *testing.T) {
	configYAML := clientRouteTestConfig + `
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [8443]
  skip-domain:
    - +.push.apple.com
`
	for _, mode := range []ClientManagedRouteMode{
		clientManagedRouteBypassMainland,
		clientManagedRouteBypassOverseas,
	} {
		merged, err := applyClientRouteOverlay(
			configYAML,
			&ClientRouteOverlay{Managed: &ClientManagedRouting{Mode: mode}},
		)
		if err != nil {
			t.Fatalf("mode %s: error = %v", mode, err)
		}
		var document map[string]any
		if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
			t.Fatalf("mode %s: merged YAML error = %v", mode, err)
		}
		sniffer, _ := document["sniffer"].(map[string]any)
		if got := anyStrings(sniffer["skip-domain"].([]any)); strings.Join(got, "\x00") != "+.push.apple.com" {
			t.Fatalf("mode %s changed skip-domain: %#v", mode, got)
		}
	}
}

func TestManagedServerGroupPreservesWhitespaceDistinctProxyNames(t *testing.T) {
	configYAML := `
mixed-port: 7890
proxies:
  - name: "日本"
    type: socks5
    server: 192.0.2.10
    port: 1080
  - name: "日本 "
    type: socks5
    server: 192.0.2.11
    port: 1080
proxy-groups:
  - name: Auto
    type: url-test
    proxies:
      - "日本"
      - "日本 "
  - name: Proxy
    type: select
    proxies:
      - Auto
      - "日本"
      - "日本 "
rules:
  - MATCH,Proxy
`
	merged, err := applyClientRouteOverlay(
		configYAML,
		&ClientRouteOverlay{Managed: &ClientManagedRouting{}},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	var document map[string]any
	if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	groups, _ := document["proxy-groups"].([]any)
	managed, _ := groups[len(groups)-1].(map[string]any)
	members, _ := managed["proxies"].([]any)
	want := []string{"Auto", "日本", "日本 "}
	if strings.Join(anyStrings(members), "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("managed server members = %#v, want %#v", members, want)
	}
}

func TestManagedDNSIsNotPinnedToAutomaticGroup(t *testing.T) {
	configYAML := `
mixed-port: 7890
proxies:
  - name: return-node
    type: socks5
    server: 192.0.2.10
    port: 1080
proxy-groups:
  - name: " 自动海外 DNS "
    type: url-test
    proxies:
      - return-node
  - name: Proxy
    type: select
    proxies:
      - " 自动海外 DNS "
      - return-node
rules:
  - MATCH,Proxy
`
	merged, err := applyClientRouteOverlay(
		configYAML,
		&ClientRouteOverlay{Managed: &ClientManagedRouting{}},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	var document map[string]any
	if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	dns, _ := document["dns"].(map[string]any)
	want := []string{
		clientOtherDNS,
	}
	if got := anyStrings(dns["nameserver"].([]any)); strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("managed nameservers = %#v, want %#v", got, want)
	}
}

func TestApplyClientRouteOverlayAllowsManagedConfigWithoutAutomaticGroup(t *testing.T) {
	configYAML := `
proxies:
  - name: node
    type: socks5
    server: 192.0.2.10
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - node
rules:
  - MATCH,Proxy
`
	merged, err := applyClientRouteOverlay(
		configYAML,
		&ClientRouteOverlay{Managed: &ClientManagedRouting{}},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	var document map[string]any
	if err := commonYaml.Unmarshal([]byte(merged), &document); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	dns, _ := document["dns"].(map[string]any)
	if dns["respect-rules"] != true {
		t.Fatalf("managed DNS does not follow IP rules: %#v", dns)
	}
}

func TestManagedRoutingKeepsLocalRuleProviderAheadOfIPPolicy(t *testing.T) {
	merged, err := applyClientRouteOverlay(
		clientRouteTestConfig,
		&ClientRouteOverlay{
			Rules: []string{"RULE-SET,wechat,DIRECT"},
			RuleProviders: map[string]ClientRuleProviderConfig{
				"wechat": {
					URL:      "https://example.com/wechat.mrs",
					Behavior: "domain",
					Format:   "mrs",
					Interval: 86400,
				},
			},
			Managed: &ClientManagedRouting{
				Mode: clientManagedRouteBypassMainland,
			},
		},
	)
	if err != nil {
		t.Fatalf("error = %v", err)
	}
	var view clientRouteConfigView
	if err := commonYaml.Unmarshal([]byte(merged), &view); err != nil {
		t.Fatalf("merged YAML error = %v", err)
	}
	if len(view.Rules) < 2 || !strings.HasPrefix(view.Rules[0], "RULE-SET,__neutralvendor_local_") {
		t.Fatalf("local provider rule is not first: %#v", view.Rules)
	}
	if len(view.RuleProviders) != 1 {
		t.Fatalf("local provider missing: %#v", view.RuleProviders)
	}
	wantRules := append(
		[]string{view.Rules[0]},
		buildClientManagedRules(
			clientManagedServerGroup,
			&ClientManagedRouting{Mode: clientManagedRouteBypassMainland},
		)...,
	)
	if strings.Join(view.Rules, "\n") != strings.Join(wantRules, "\n") {
		t.Fatalf("managed IP policy changed: %#v", view.Rules)
	}
}

func anyStrings(values []any) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, fmt.Sprint(value))
	}
	return result
}

func TestBuildClientManagedRulesKeepsGlobalModes(t *testing.T) {
	tests := []struct {
		name         string
		mode         ClientManagedRouteMode
		wantMainland string
		wantOverseas string
	}{
		{"global", clientManagedRouteGlobal, "Proxy", "Proxy"},
		{"legacy direct all", clientManagedRouteDirectAllLegacy, "DIRECT", "DIRECT"},
	}
	for _, test := range tests {
		for _, rejectIPv6 := range []bool{false, true} {
			name := fmt.Sprintf("%s/reject-ipv6=%t", test.name, rejectIPv6)
			t.Run(name, func(t *testing.T) {
				got := buildClientManagedRules(
					"Proxy",
					&ClientManagedRouting{
						Mode:       test.mode,
						RejectIPv6: rejectIPv6,
					},
				)
				want := []string{
					"GEOIP,private,DIRECT,no-resolve",
					"GEOIP,LAN,DIRECT,no-resolve",
				}
				if rejectIPv6 {
					want = append(want, "IP-CIDR6,::/0,REJECT,no-resolve")
				}
				want = append(want,
					"GEOSITE,google,"+test.wantOverseas,
					"GEOSITE,youtube,"+test.wantOverseas,
					"GEOSITE,google-play,"+test.wantOverseas,
					"GEOSITE,cn,"+test.wantMainland,
					"GEOIP,CN,"+test.wantMainland,
					"MATCH,"+test.wantOverseas,
				)
				if strings.Join(got, "\n") != strings.Join(want, "\n") {
					t.Fatalf("managed rules = %#v, want %#v", got, want)
				}
			})
		}
	}
}

func TestBuildClientManagedRulesMatchesV2rayNGSplitPolicy(t *testing.T) {
	dnsAddressRules := []string{
		"IP-CIDR,223.5.5.5/32", "IP-CIDR,223.6.6.6/32",
		"IP-CIDR6,2400:3200::1/128", "IP-CIDR6,2400:3200:baba::1/128",
		"IP-CIDR,119.29.29.29/32", "IP-CIDR,1.12.12.12/32",
		"IP-CIDR,120.53.53.53/32", "IP-CIDR6,2402:4e00::/128",
		"IP-CIDR6,2402:4e00:1::/128", "IP-CIDR,180.76.76.76/32",
		"IP-CIDR6,2400:da00::6666/128", "IP-CIDR,114.114.114.114/32",
		"IP-CIDR,114.114.115.115/32", "IP-CIDR,114.114.114.119/32",
		"IP-CIDR,114.114.115.119/32", "IP-CIDR,114.114.114.110/32",
		"IP-CIDR,114.114.115.110/32", "IP-CIDR,180.184.1.1/32",
		"IP-CIDR,180.184.2.2/32", "IP-CIDR,101.226.4.6/32",
		"IP-CIDR,218.30.118.6/32", "IP-CIDR,123.125.81.6/32",
		"IP-CIDR,140.207.198.6/32", "IP-CIDR,1.2.4.8/32",
		"IP-CIDR,210.2.4.8/32", "IP-CIDR,52.80.66.66/32",
		"IP-CIDR,117.50.22.22/32", "IP-CIDR6,2400:7fc0:849e:200::4/128",
		"IP-CIDR6,2404:c2c0:85d8:901::4/128", "IP-CIDR,117.50.10.10/32",
		"IP-CIDR,52.80.52.52/32", "IP-CIDR6,2400:7fc0:849e:200::8/128",
		"IP-CIDR6,2404:c2c0:85d8:901::8/128", "IP-CIDR,117.50.60.30/32",
		"IP-CIDR,52.80.60.30/32",
	}
	tests := []struct {
		mode           ClientManagedRouteMode
		mainlandTarget string
		overseasTarget string
	}{
		{clientManagedRouteBypassMainland, "DIRECT", "Proxy"},
		{clientManagedRouteBypassOverseas, "Proxy", "DIRECT"},
	}
	for _, test := range tests {
		rules := buildClientManagedRules(
			"Proxy",
			&ClientManagedRouting{Mode: test.mode},
		)
		want := []string{
			"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",
		}
		if test.mode == clientManagedRouteBypassOverseas {
			for _, geosite := range clientReturnGeoSites {
				want = append(want, "GEOSITE,"+geosite+","+test.mainlandTarget)
			}
		}
		want = append(want,
			"GEOSITE,google,"+test.overseasTarget,
			"GEOSITE,youtube,"+test.overseasTarget,
			"GEOSITE,google-play,"+test.overseasTarget,
			"GEOIP,private,DIRECT,no-resolve",
			"GEOIP,LAN,DIRECT,no-resolve",
			"GEOSITE,private,DIRECT",
		)
		for _, rule := range dnsAddressRules {
			want = append(want, rule+","+test.mainlandTarget+",no-resolve")
		}
		want = append(want,
			"DOMAIN-SUFFIX,alidns.com,"+test.mainlandTarget,
			"DOMAIN-SUFFIX,doh.pub,"+test.mainlandTarget,
			"DOMAIN-SUFFIX,dot.pub,"+test.mainlandTarget,
			"DOMAIN-SUFFIX,360.cn,"+test.mainlandTarget,
			"DOMAIN-SUFFIX,onedns.net,"+test.mainlandTarget,
			"GEOIP,CN,"+test.mainlandTarget+",no-resolve",
			"GEOSITE,cn,"+test.mainlandTarget,
			"MATCH,"+test.overseasTarget,
		)
		if strings.Join(rules, "\n") != strings.Join(want, "\n") {
			t.Fatalf("mode %s rules = %#v, want %#v", test.mode, rules, want)
		}
		if strings.Contains(strings.Join(rules, "\n"), "IP-CIDR6,::/0,REJECT") {
			t.Fatalf("mode %s rejected all IPv6: %#v", test.mode, rules)
		}
	}
}

func TestClientManagedRoutingReadsAllLegacyFlagCombinations(t *testing.T) {
	tests := []struct {
		name string
		json string
		mode ClientManagedRouteMode
	}{
		{"global", `{"bypass-mainland":false,"bypass-overseas":false}`, clientManagedRouteGlobal},
		{"bypass mainland", `{"bypass-mainland":true,"bypass-overseas":false}`, clientManagedRouteBypassMainland},
		{"bypass overseas", `{"bypass-mainland":false,"bypass-overseas":true}`, clientManagedRouteBypassOverseas},
		{"direct all", `{"bypass-mainland":true,"bypass-overseas":true}`, clientManagedRouteDirectAllLegacy},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var routing ClientManagedRouting
			if err := json.Unmarshal([]byte(test.json), &routing); err != nil {
				t.Fatalf("legacy routing decode error = %v", err)
			}
			if routing.Mode != test.mode {
				t.Fatalf("legacy routing mode = %q, want %q", routing.Mode, test.mode)
			}
		})
	}
}

func TestClientManagedRoutingPrefersNewModeAndWritesBothFormats(t *testing.T) {
	var routing ClientManagedRouting
	input := `{"mode":"bypass-overseas","bypass-mainland":true,"bypass-overseas":true,"reject-ipv6":true}`
	if err := json.Unmarshal([]byte(input), &routing); err != nil {
		t.Fatalf("routing decode error = %v", err)
	}
	if routing.Mode != clientManagedRouteBypassOverseas || !routing.RejectIPv6 {
		t.Fatalf("new route mode did not win: %#v", routing)
	}

	wire, err := json.Marshal(routing)
	if err != nil {
		t.Fatalf("routing encode error = %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(wire, &got); err != nil {
		t.Fatalf("routing wire decode error = %v", err)
	}
	if got["mode"] != "bypass-overseas" ||
		got["bypass-mainland"] != false ||
		got["bypass-overseas"] != true ||
		got["reject-ipv6"] != true {
		t.Fatalf("routing compatibility wire = %s", wire)
	}
}

func TestClientManagedRoutingRejectsUnknownNewMode(t *testing.T) {
	var routing ClientManagedRouting
	err := json.Unmarshal(
		[]byte(`{"mode":"future-mode","bypass-mainland":true}`),
		&routing,
	)
	if err == nil || err.Error() != "invalid managed route mode" {
		t.Fatalf("unknown route mode error = %v", err)
	}
}

func TestClientManagedRoutingRejectsNullNewMode(t *testing.T) {
	var routing ClientManagedRouting
	err := json.Unmarshal(
		[]byte(`{"mode":null,"bypass-mainland":true}`),
		&routing,
	)
	if err == nil || err.Error() != "invalid managed route mode" {
		t.Fatalf("null route mode error = %v", err)
	}
}

func TestApplyClientRouteOverlayRejectsManagedConfigWithoutProxies(t *testing.T) {
	_, err := applyClientRouteOverlay(
		"rules:\n  - MATCH,DIRECT\n",
		&ClientRouteOverlay{Managed: &ClientManagedRouting{}},
	)
	if err == nil || err.Error() != "managed proxy group missing" {
		t.Fatalf("error = %v", err)
	}
}
