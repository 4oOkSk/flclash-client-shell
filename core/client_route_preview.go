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

func previewRuleMatch(rule C.Rule, metadata *C.Metadata, depth int, budget *int) (bool, string) {
	*budget--
	if depth > 16 || *budget < 0 {
		return false, "needs-context"
	}
	if wrapper, ok := rule.(C.RuleWrapper); ok {
		if wrapper.IsDisabled() {
			return false, ""
		}
		return previewRuleMatch(wrapper.Unwrap(), metadata, depth+1, budget)
	}
	switch rule.RuleType() {
	case C.AND, C.OR, C.NOT:
		logical, ok := rule.(interface{ Rules() []C.Rule })
		if !ok {
			return false, "needs-context"
		}
		children := logical.Rules()
		if len(children) == 0 || (rule.RuleType() == C.NOT && len(children) != 1) {
			return false, "needs-context"
		}
		unknown := ""
		for _, child := range children {
			matched, reason := previewRuleMatch(child, metadata, depth+1, budget)
			if reason != "" {
				unknown = reason
				continue
			}
			if rule.RuleType() == C.NOT {
				return !matched, ""
			}
			if rule.RuleType() == C.AND && !matched {
				return false, ""
			}
			if rule.RuleType() == C.OR && matched {
				return true, ""
			}
		}
		return rule.RuleType() == C.AND && unknown == "", unknown
	case C.Domain, C.DomainSuffix, C.DomainKeyword, C.DomainRegex, C.DomainWildcard, C.GEOSITE, C.MATCH, C.Network, C.DstPort:
	case C.IPCIDR, C.IPSuffix, C.GEOIP, C.IPASN:
		if !metadata.DstIP.IsValid() {
			return false, "needs-ip"
		}
	default:
		return false, "needs-context"
	}
	unknown := ""
	matched, _ := rule.Match(metadata, C.RuleMatchHelper{
		ResolveIP: func() {
			if !metadata.DstIP.IsValid() {
				unknown = "needs-ip"
			}
		},
		FindProcess:   func() { unknown = "needs-context" },
		CheckPassRule: func(string) bool { return false },
	})
	return matched, unknown
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
		budget := 256
		matched, unknown := previewRuleMatch(rule, metadata, 0, &budget)
		if unknown != "" {
			return clientRoutePreview{Status: unknown, RuleIndex: index + 1}
		}
		if !matched {
			continue
		}
		action := "proxy"
		switch rule.Adapter() {
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
