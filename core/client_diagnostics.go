package main

import (
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	coreAtomic "github.com/metacubex/mihomo/common/atomic"
	commonYaml "github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var clientDiagnosticEndpoints atomic.Value
var clientDiagnosticConfigMu sync.Mutex

var clientDiagnosticAddressPattern = regexp.MustCompile(`(?i)(?:\[[0-9a-f:.]+\]|[0-9a-f]*:[0-9a-f:]*:[0-9a-f:]+|[a-z0-9][a-z0-9._-]*)(?::[0-9]+)?`)

type clientDiagnosticEndpointSet struct {
	mu      sync.RWMutex
	hosts   map[string]map[uint16]struct{}
	secrets []string
}

func setClientDiagnosticEndpoints(configText string) {
	var document map[string]any
	if commonYaml.Unmarshal([]byte(configText), &document) == nil {
		proxies, _ := document["proxies"].([]any)
		for _, raw := range proxies {
			proxy, _ := raw.(map[string]any)
			registerClientDiagnosticProxy(proxy)
		}
		providers, _ := document["proxy-providers"].(map[string]any)
		for _, raw := range providers {
			provider, _ := raw.(map[string]any)
			payload, _ := provider["payload"].([]any)
			for _, item := range payload {
				proxy, _ := item.(map[string]any)
				registerClientDiagnosticProxy(proxy)
			}
		}
	}
}

func registerClientDiagnosticProxy(proxy map[string]any) {
	clientDiagnosticConfigMu.Lock()
	defer clientDiagnosticConfigMu.Unlock()
	endpoints, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet)
	if endpoints == nil {
		endpoints = &clientDiagnosticEndpointSet{hosts: map[string]map[uint16]struct{}{}}
		clientDiagnosticEndpoints.Store(endpoints)
	}
	endpoints.mu.Lock()
	defer endpoints.mu.Unlock()
	endpoints.collectSecrets(proxy)
	port, err := strconv.Atoi(fmt.Sprint(proxy["port"]))
	if err == nil && port > 0 && port <= 65535 {
		for _, key := range []string{"server", "servername", "sni"} {
			if host, _ := proxy[key].(string); host != "" {
				endpoints.add(host, uint16(port))
			}
		}
	}
	sort.Slice(endpoints.secrets, func(first, second int) bool { return len(endpoints.secrets[first]) > len(endpoints.secrets[second]) })
	endpoints.secrets = compactDiagnosticSecrets(endpoints.secrets)
}

func compactDiagnosticSecrets(values []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value != "" && !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return result
}

func (endpoints *clientDiagnosticEndpointSet) collectSecrets(document map[string]any) {
	for key, raw := range document {
		if nested, ok := raw.(map[string]any); ok {
			endpoints.collectSecrets(nested)
		}
		if items, ok := raw.([]any); ok {
			for _, item := range items {
				if nested, ok := item.(map[string]any); ok {
					endpoints.collectSecrets(nested)
				}
			}
		}
		switch strings.ToLower(key) {
		case "server", "servername", "sni", "host":
			if value, ok := raw.(string); ok && value != "" {
				endpoints.add(value, 0)
			}
		}
		switch strings.ToLower(key) {
		case "name", "password", "passwd", "uuid", "username", "token", "private-key", "public-key", "pre-shared-key", "short-id", "path", "host", "authorization", "cookie", "auth", "auth-str", "obfs-password":
			if value, ok := raw.(string); ok && value != "" {
				endpoints.secrets = append(endpoints.secrets, value, url.QueryEscape(value), url.PathEscape(value))
			}
		}
	}
}

var clientDiagnosticURLPattern = regexp.MustCompile(`(?i)\b(?:https?|socks5?|vless|vmess|trojan|hysteria2?|hy2|ss)://[^\s<>]+`)
var clientDiagnosticCredentialPattern = regexp.MustCompile(`(?i)\b(?:password|passwd|token|authorization|cookie|uuid|server|port|sni|private-key|public-key|short-id)\s*["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;}]+)`)

func sanitizeClientDiagnosticMessage(payload string) string {
	payload = clientDiagnosticURLPattern.ReplaceAllString(payload, "[url]")
	return clientDiagnosticCredentialPattern.ReplaceAllString(payload, "[credential]")
}

func clientDiagnosticHost(host string) string {
	host = strings.ToLower(strings.Trim(strings.TrimSpace(host), "[]."))
	if address, err := netip.ParseAddr(host); err == nil {
		return address.Unmap().String()
	}
	return host
}

func (endpoints *clientDiagnosticEndpointSet) add(host string, port uint16) {
	host = clientDiagnosticHost(host)
	if endpoints.hosts[host] == nil {
		endpoints.hosts[host] = map[uint16]struct{}{}
	}
	endpoints.hosts[host][port] = struct{}{}
}

func (endpoints *clientDiagnosticEndpointSet) recordAddresses(host string, addresses []netip.Addr) {
	endpoints.mu.Lock()
	for port := range endpoints.hosts[clientDiagnosticHost(host)] {
		for _, address := range addresses {
			endpoints.add(address.String(), port)
		}
	}
	endpoints.mu.Unlock()
	if current, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet); current != nil && current != endpoints {
		current.recordAddresses(host, addresses)
	}
}

func sanitizeClientLogPayload(payload string) string {
	payload = sanitizeClientDiagnosticMessage(payload)
	endpoints, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet)
	if endpoints == nil {
		return sanitizeClientDiagnosticMessage(payload)
	}
	endpoints.mu.RLock()
	defer endpoints.mu.RUnlock()
	protected := false
	payload = clientDiagnosticAddressPattern.ReplaceAllStringFunc(payload, func(value string) string {
		host := value
		if address, _, err := net.SplitHostPort(value); err == nil {
			host = address
		}
		if len(endpoints.hosts[clientDiagnosticHost(host)]) != 0 {
			protected = true
			return "[server-endpoint]"
		}
		return value
	})
	if protected && strings.Contains(strings.ToLower(payload), "dns") {
		return "[DNS] [server-endpoint] lookup details withheld"
	}
	for _, secret := range endpoints.secrets {
		payload = strings.ReplaceAll(payload, secret, "[private]")
	}
	return sanitizeClientDiagnosticMessage(payload)
}

func clientDiagnosticDestination(metadata *constant.Metadata) string {
	if metadata == nil {
		return "unknown"
	}
	endpoints, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet)
	if endpoints == nil {
		return "destination"
	}
	endpoints.mu.RLock()
	defer endpoints.mu.RUnlock()
	for _, host := range []string{metadata.Host, metadata.SniffHost, metadata.DstIP.String()} {
		if len(endpoints.hosts[clientDiagnosticHost(host)]) != 0 {
			return "server-endpoint"
		}
	}
	return "destination"
}

// Copy before redacting: the live metadata and counters still belong to routing.
func clientDiagnosticTracker(source *statistic.TrackerInfo) *statistic.TrackerInfo {
	if source == nil {
		return nil
	}
	result := &statistic.TrackerInfo{
		UUID:          source.UUID,
		Start:         source.Start,
		UploadTotal:   coreAtomic.NewInt64(source.UploadTotal.Load()),
		DownloadTotal: coreAtomic.NewInt64(source.DownloadTotal.Load()),
		Rule:          source.Rule,
		Lifecycle:     source.Lifecycle,
		DurationMs:    source.DurationMs,
		EndReason:     source.EndReason,
	}
	if source.Metadata != nil {
		result.Metadata = source.Metadata.Clone()
		result.Metadata.SrcGeoIP = append([]string(nil), source.Metadata.SrcGeoIP...)
		result.Metadata.DstGeoIP = append([]string(nil), source.Metadata.DstGeoIP...)
		result.Metadata.RemoteDst = ""
		result.Metadata.SpecialProxy = ""
		result.Metadata.SpecialRules = ""
		result.Metadata.RematchName = ""
		result.Metadata.InUser = ""
	}
	result.DiagnosticRoute = clientDiagnosticRoute(source.Chain)
	result.DiagnosticRule = clientDiagnosticRule(source.Rule)
	result.DiagnosticPolicy = clientDiagnosticPolicy(source.Rule, source.RulePayload)
	result.DiagnosticDestination = clientDiagnosticDestination(source.Metadata)
	result.Chain = constant.Chain{strings.ToUpper(result.DiagnosticRoute)}
	result.ProviderChain = constant.Chain{}
	if result.Metadata != nil && result.DiagnosticDestination == "server-endpoint" {
		result.Metadata.Host = ""
		result.Metadata.SniffHost = ""
		result.Metadata.DstIP = netip.Addr{}
		result.Metadata.DstPort = 0
		result.Metadata.DstGeoIP = nil
		result.Metadata.DstIPASN = ""
	}
	return result
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
	case rule == "geosite" && (value == "cn" || value == "geolocation-cn" || value == "tld-cn"):
		return "mainland-domain"
	case rule == "geoip" && value == "cn":
		return "mainland-ip"
	case rule == "match":
		return "fallback"
	default:
		return "other"
	}
}

