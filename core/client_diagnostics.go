package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync/atomic"

	commonYaml "github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var clientDiagnosticEndpoints atomic.Value

func setClientDiagnosticEndpoints(configText string) {
	endpoints := map[string]struct{}{}
	var document map[string]any
	if commonYaml.Unmarshal([]byte(configText), &document) == nil {
		proxies, _ := document["proxies"].([]any)
		for _, raw := range proxies {
			proxy, _ := raw.(map[string]any)
			port, err := strconv.Atoi(fmt.Sprint(proxy["port"]))
			if err != nil || port < 1 || port > 65535 {
				continue
			}
			for _, key := range []string{"server", "servername", "sni"} {
				host, _ := proxy[key].(string)
				if host != "" {
					endpoints[clientDiagnosticEndpoint(host, uint16(port))] = struct{}{}
				}
			}
		}
	}
	clientDiagnosticEndpoints.Store(endpoints)
}

func clientDiagnosticEndpoint(host string, port uint16) string {
	return net.JoinHostPort(strings.ToLower(strings.Trim(strings.TrimSpace(host), "[].")), strconv.Itoa(int(port)))
}

func clientDiagnosticDestination(metadata *constant.Metadata) string {
	if metadata == nil {
		return "unknown"
	}
	endpoints, _ := clientDiagnosticEndpoints.Load().(map[string]struct{})
	for _, host := range []string{metadata.Host, metadata.DstIP.String()} {
		if _, exists := endpoints[clientDiagnosticEndpoint(host, metadata.DstPort)]; exists {
			return "server-endpoint"
		}
	}
	return "destination"
}

// annotateClientTrackerDiagnostics reduces routing details to a fixed set of
// troubleshooting categories before the tracker crosses the core boundary.
// Raw rule payloads and proxy-chain names never need to reach the report.
func annotateClientTrackerDiagnostics(info *statistic.TrackerInfo) {
	if info == nil {
		return
	}
	info.DiagnosticRoute = clientDiagnosticRoute(info.Chain)
	info.DiagnosticRule = clientDiagnosticRule(info.Rule)
	info.DiagnosticPolicy = clientDiagnosticPolicy(info.Rule, info.RulePayload)
	info.DiagnosticDestination = clientDiagnosticDestination(info.Metadata)
}

func clientDiagnosticRoute(chain []string) string {
	for _, item := range chain {
		switch strings.ToUpper(strings.TrimSpace(item)) {
		case "REJECT", "REJECT-DROP":
			return "reject"
		case "DIRECT":
			return "direct"
		}
	}
	if len(chain) == 0 {
		return "unknown"
	}
	return "proxy"
}

func clientDiagnosticRule(ruleType string) string {
	switch strings.ToLower(strings.TrimSpace(ruleType)) {
	case "domain", "domainsuffix", "domainkeyword", "domainregex", "domainwildcard", "geosite":
		return "domain"
	case "geoip", "srcgeoip", "ipasn", "srcipasn", "ipcidr", "srcipcidr", "ipsuffix", "srcipsuffix":
		return "ip"
	case "ruleset":
		return "rule-set"
	case "match":
		return "match"
	case "srcport", "dstport", "inport", "network", "dscp":
		return "transport"
	case "processname", "processpath", "processnameregex", "processpathregex", "processnamewildcard", "processpathwildcard", "uid":
		return "process"
	case "":
		return "none"
	default:
		return "other"
	}
}

func clientDiagnosticPolicy(ruleType string, payload string) string {
	rule := strings.ToLower(strings.TrimSpace(ruleType))
	value := strings.ToLower(strings.TrimSpace(payload))
	switch {
	case rule == "geosite" && value == "private":
		return "private"
	case rule == "geoip" && (value == "private" || value == "lan"):
		return "private"
	case rule == "ipcidr" && value == "::/0":
		return "ipv6-block"
	case rule == "domain" && (value == "us.ip111.cn" || value == "perfops2.byte-test.com"):
		return "probe"
	case rule == "geosite" && (value == "google" || value == "youtube" || value == "google-play"):
		return "overseas-service"
	case rule == "geosite" && value == "geolocation-!cn":
		return "overseas-domain"
	case rule == "geosite" && (value == "cn" || value == "geolocation-cn" || value == "tld-cn" || clientReturnGeoSite(value)):
		return "mainland-domain"
	case rule == "geoip" && value == "cn":
		return "mainland-ip"
	case rule == "match":
		return "fallback"
	case rule == "ruleset" && strings.HasPrefix(value, "__neutralvendor_local_"):
		return "local"
	default:
		return "other"
	}
}

func clientReturnGeoSite(value string) bool {
	for _, geosite := range clientReturnGeoSites {
		if value == geosite {
			return true
		}
	}
	return false
}
