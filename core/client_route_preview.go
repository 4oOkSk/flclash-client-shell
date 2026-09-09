package main

import (
	"encoding/json"
	"net/netip"
	"strings"

	C "github.com/metacubex/mihomo/constant"
)

type clientRoutePreview struct {
	Status    string `json:"status"`
	Action    string `json:"action,omitempty"`
	RuleIndex int    `json:"rule-index,omitempty"`
	RuleType  string `json:"rule-type,omitempty"`
}

func previewClientRouteRules(destination string, rules []C.Rule) clientRoutePreview {
	destination = strings.ToLower(strings.TrimSpace(destination))
	if destination == "" || len(destination) > 253 || strings.ContainsAny(destination, " /\\,@?#\r\n\t") {
		return clientRoutePreview{Status: "invalid"}
	}
	metadata := &C.Metadata{NetWork: C.TCP, Type: C.HTTP, DstPort: 443}
	address, err := netip.ParseAddr(destination)
	if err == nil {
		metadata.DstIP = address
	} else {
		if !strings.Contains(destination, ".") {
			return clientRoutePreview{Status: "invalid"}
		}
		metadata.Host = destination
	}
	for index, rule := range rules {
		if wrapper, ok := rule.(C.RuleWrapper); ok {
			if wrapper.IsDisabled() {
				continue
			}
			rule = wrapper.Unwrap()
		}
		switch rule.RuleType() {
		case C.Domain, C.DomainSuffix, C.DomainKeyword, C.DomainRegex, C.DomainWildcard, C.GEOSITE, C.MATCH, C.Network, C.DstPort:
		case C.IPCIDR, C.IPSuffix, C.GEOIP, C.IPASN:
			if !metadata.DstIP.IsValid() {
				return clientRoutePreview{Status: "needs-ip", RuleIndex: index + 1}
			}
		default:
			return clientRoutePreview{Status: "needs-context", RuleIndex: index + 1}
		}
		needsContext := false
		matched, target := rule.Match(metadata, C.RuleMatchHelper{
			ResolveIP: func() {
				if !metadata.DstIP.IsValid() {
					needsContext = true
				}
			},
			FindProcess:   func() { needsContext = true },
			CheckPassRule: func(string) bool { return false },
		})
		if needsContext {
			return clientRoutePreview{Status: "needs-context", RuleIndex: index + 1}
		}
		if !matched {
			continue
		}
		action := "proxy"
		switch target {
		case "DIRECT":
			action = "direct"
		case "REJECT", "REJECT-DROP":
			action = "reject"
		}
		return clientRoutePreview{
			Status: "matched", Action: action,
			RuleIndex: index + 1, RuleType: rule.RuleType().String(),
		}
	}
	return clientRoutePreview{Status: "unavailable"}
}

func clientRoutePreviewJSON(destination string) string {
	runLock.Lock()
	defer runLock.Unlock()
	result := clientRoutePreview{Status: "unavailable"}
	if currentConfig != nil && privateConfig && clientHasSession() {
		result = previewClientRouteRules(destination, currentConfig.Rules)
	}
	data, _ := json.Marshal(result)
	return string(data)
}
