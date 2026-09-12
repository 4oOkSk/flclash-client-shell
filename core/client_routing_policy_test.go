package main

import (
	"net/netip"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

func TestSharedRoutingPolicyData(t *testing.T) {
	if len(clientRoutingPolicy.GoogleSites) != 3 || len(clientReturnGeoSites) != 4 || len(clientRoutingPolicy.MainlandDNSIP) != 35 {
		t.Fatal("historical category or DNS coverage changed")
	}
	seen := map[string]bool{}
	for _, value := range clientRoutingPolicy.MainlandDNSIP {
		prefix, err := netip.ParsePrefix(value)
		if err != nil || prefix != prefix.Masked() || seen[value] {
			t.Fatalf("invalid or duplicate DNS prefix %q", value)
		}
		seen[value] = true
	}
}

func TestManagedRoutingHistoricalDestinations(t *testing.T) {
	home := C.Path.HomeDir()
	geoMode := geodata.GeodataMode()
	geoSiteName, geoIPName := C.GeositeName, C.GeoipName
	data, err := filepath.Abs("../assets/data")
	if err != nil {
		t.Fatal(err)
	}
	C.SetHomeDir(data)
	C.Path.GeoSite()
	C.Path.GeoIP()
	geodata.SetGeodataMode(true)
	geodata.ClearGeoSiteCache()
	geodata.ClearGeoIPCache()
	t.Cleanup(func() {
		geodata.ClearGeoSiteCache()
		geodata.ClearGeoIPCache()
		C.SetHomeDir(home)
		C.GeositeName, C.GeoipName = geoSiteName, geoIPName
		geodata.SetGeodataMode(geoMode)
	})
	for _, mode := range []ClientManagedRouteMode{clientManagedRouteGlobal, clientManagedRouteBypassMainland, clientManagedRouteBypassOverseas} {
		merged, err := applyClientRouteOverlay(clientRouteTestConfig, &ClientRouteOverlay{Managed: &ClientManagedRouting{Mode: mode}})
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := config.Parse([]byte(merged))
		if err != nil {
			t.Fatal(err)
		}
		for _, sample := range []struct {
			host     string
			mainland bool
			returnCN bool
		}{
			{"www.google.com", false, false},
			{"www.recaptcha.net", false, false},
			{"recaptcha.net", false, false},
			{"googleapis.cn", false, false},
			{"fonts.googleapis.com", false, false},
			{"dl.google.com", false, false},
			{"redirector.gvt1.com", false, false},
			{"rr1.xn--ngstr-lra8j.com", false, false},
			{"play.googleapis.com", false, false},
			{"android.clients.google.com", false, false},
			{"services.googleapis.cn", false, false},
			{"www.youtube.com", false, false},
			{"c2c.cdn.weixin.qq.com", true, true},
			{"extshort.weixin.qq.com", true, true},
			{"sns-na-i28.xhscdn.com", true, true},
			{"gslb.xiaohongshu.com", true, true},
			{"www.bilibili.com", true, true},
			{"apps.apple.com", false, true},
			{"download.windowsupdate.com", true, true},
			{"steamstatic.com.8686c.com", true, true},
			{"unlisted-routing-fixture-20260912.com", false, false},
		} {
			t.Run(string(mode)+"/"+sample.host, func(t *testing.T) {
				want := clientManagedServerGroup
				if mode == clientManagedRouteBypassMainland && sample.mainland || mode == clientManagedRouteBypassOverseas && !sample.returnCN {
					want = "DIRECT"
				}
				assertManagedRuleTarget(t, parsed, &C.Metadata{Host: sample.host, DstPort: 443, NetWork: C.TCP}, want)
				wantDNS := clientOtherDNS
				if sample.mainland || mode == clientManagedRouteBypassOverseas && sample.returnCN {
					wantDNS = clientMainlandDNS
				}
				servers := parsed.DNS.NameServer
				for _, policy := range parsed.DNS.NameServerPolicy {
					if policy.Matcher != nil && policy.Matcher.MatchDomain(sample.host) {
						servers = policy.NameServers
						break
					}
				}
				if len(servers) != 1 || strings.Replace(servers[0].Addr, ":443/", "/", 1) != wantDNS || servers[0].ProxyName != "RULES" {
					t.Fatalf("DNS target = %#v, want %s", servers, wantDNS)
				}
			})
		}
		for _, network := range []C.NetWork{C.TCP, C.UDP} {
			for _, address := range []string{"192.168.1.1", "fd00::1"} {
				assertManagedRuleTarget(t, parsed, &C.Metadata{DstIP: netip.MustParseAddr(address), DstPort: 443, NetWork: network}, "DIRECT")
			}
			assertManagedRuleTarget(t, parsed, &C.Metadata{Host: "nas.lan", DstPort: 443, NetWork: network}, "DIRECT")
		}
		publicUDP := clientManagedServerGroup
		if mode.splitPolicy() {
			publicUDP = "REJECT"
		}
		assertManagedRuleTarget(t, parsed, &C.Metadata{DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 443, NetWork: C.UDP}, publicUDP)
		for _, endpoint := range []string{clientMainlandDNS, clientOtherDNS} {
			address := strings.TrimSuffix(strings.TrimPrefix(endpoint, "https://"), "/dns-query")
			want := clientManagedServerGroup
			if mode == clientManagedRouteBypassMainland && endpoint == clientMainlandDNS || mode == clientManagedRouteBypassOverseas && endpoint == clientOtherDNS {
				want = "DIRECT"
			}
			assertManagedRuleTarget(t, parsed, &C.Metadata{DstIP: netip.MustParseAddr(address), DstPort: 443, NetWork: C.TCP}, want)
		}
	}
}

func assertManagedRuleTarget(t *testing.T, parsed *config.Config, metadata *C.Metadata, want string) {
	t.Helper()
	helper := C.RuleMatchHelper{ResolveIP: func() { t.Fatal("route selection unexpectedly initiated DNS") }}
	for _, rule := range parsed.Rules {
		if matched, target := rule.Match(metadata, helper); matched {
			if target != want {
				t.Fatalf("%s:%d/%s target = %s, want %s", metadata.String(), metadata.DstPort, metadata.NetWork, target, want)
			}
			return
		}
	}
	t.Fatal("managed rules have no final match")
}
