package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"unicode"

	commonYaml "github.com/metacubex/mihomo/common/yaml"
	ruleCommon "github.com/metacubex/mihomo/rules/common"
)

const (
	clientRouteOverlayErrorPrefix = "client route overlay invalid"
	clientManagedServerGroup      = "HARBORPROXY-SERVER"
	maxClientRouteRules           = 5000
	maxClientRouteProviders       = 64
	maxClientRouteRuleLength      = 4096
	clientGeoIPURL                = "https://example.invalid/harborproxy/geoip.dat"
	clientGeoSiteURL              = "https://example.invalid/harborproxy/geosite.dat"
	clientMainlandDNS             = "tcp://223.5.5.5:53"
	clientOtherDNS                = "tcp://1.1.1.1:53"
	clientMainlandDNSPolicy       = "geosite:cn"
)

type ClientRouteOverlay struct {
	Rules         []string                            `json:"rules"`
	RuleProviders map[string]ClientRuleProviderConfig `json:"rule-providers"`
	Managed       *ClientManagedRouting               `json:"managed-routing"`
}

type ClientManagedRouteMode string

const (
	clientManagedRouteGlobal          ClientManagedRouteMode = "global"
	clientManagedRouteBypassMainland  ClientManagedRouteMode = "bypass-mainland"
	clientManagedRouteBypassOverseas  ClientManagedRouteMode = "bypass-overseas"
	clientManagedRouteDirectAllLegacy ClientManagedRouteMode = "direct-all"
)

type ClientManagedRouting struct {
	Mode       ClientManagedRouteMode `json:"-"`
	RejectIPv6 bool                   `json:"reject-ipv6"`
}

type clientManagedRoutingWire struct {
	Mode           json.RawMessage `json:"mode,omitempty"`
	BypassMainland *bool           `json:"bypass-mainland,omitempty"`
	BypassOverseas *bool           `json:"bypass-overseas,omitempty"`
	RejectIPv6     bool            `json:"reject-ipv6"`
}

func (mode ClientManagedRouteMode) valid() bool {
	switch mode {
	case clientManagedRouteGlobal,
		clientManagedRouteBypassMainland,
		clientManagedRouteBypassOverseas,
		clientManagedRouteDirectAllLegacy:
		return true
	default:
		return false
	}
}

func clientManagedRouteModeFromLegacy(bypassMainland, bypassOverseas bool) ClientManagedRouteMode {
	switch {
	case bypassMainland && bypassOverseas:
		return clientManagedRouteDirectAllLegacy
	case bypassMainland:
		return clientManagedRouteBypassMainland
	case bypassOverseas:
		return clientManagedRouteBypassOverseas
	default:
		return clientManagedRouteGlobal
	}
}

func (mode ClientManagedRouteMode) legacyFlags() (bypassMainland, bypassOverseas bool) {
	switch mode {
	case clientManagedRouteBypassMainland:
		return true, false
	case clientManagedRouteBypassOverseas:
		return false, true
	case clientManagedRouteDirectAllLegacy:
		return true, true
	default:
		return false, false
	}
}

func (routing ClientManagedRouting) effectiveMode() ClientManagedRouteMode {
	if routing.Mode == "" {
		// Preserve the old zero-value JSON object: both flags false meant global.
		return clientManagedRouteGlobal
	}
	return routing.Mode
}

func (routing ClientManagedRouting) MarshalJSON() ([]byte, error) {
	mode := routing.effectiveMode()
	if !mode.valid() {
		return nil, errors.New("invalid managed route mode")
	}
	modeJSON, err := json.Marshal(mode)
	if err != nil {
		return nil, err
	}
	bypassMainland, bypassOverseas := mode.legacyFlags()
	return json.Marshal(clientManagedRoutingWire{
		Mode:           modeJSON,
		BypassMainland: &bypassMainland,
		BypassOverseas: &bypassOverseas,
		RejectIPv6:     routing.RejectIPv6,
	})
}

func (routing *ClientManagedRouting) UnmarshalJSON(data []byte) error {
	var wire clientManagedRoutingWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	mode := clientManagedRouteGlobal
	if len(wire.Mode) != 0 {
		if string(wire.Mode) == "null" || json.Unmarshal(wire.Mode, &mode) != nil {
			return errors.New("invalid managed route mode")
		}
	} else {
		bypassMainland := wire.BypassMainland != nil && *wire.BypassMainland
		bypassOverseas := wire.BypassOverseas != nil && *wire.BypassOverseas
		mode = clientManagedRouteModeFromLegacy(bypassMainland, bypassOverseas)
	}
	if !mode.valid() {
		return errors.New("invalid managed route mode")
	}
	*routing = ClientManagedRouting{
		Mode:       mode,
		RejectIPv6: wire.RejectIPv6,
	}
	return nil
}

type ClientRuleProviderConfig struct {
	URL      string `json:"url"`
	Behavior string `json:"behavior"`
	Format   string `json:"format"`
	Interval int    `json:"interval"`
}

type clientRouteConfigView struct {
	ProxyGroups   []map[string]any          `yaml:"proxy-groups"`
	Rules         []string                  `yaml:"rules"`
	RuleProviders map[string]map[string]any `yaml:"rule-providers"`
}

func (overlay *ClientRouteOverlay) empty() bool {
	return overlay == nil || (len(overlay.Rules) == 0 && len(overlay.RuleProviders) == 0 && overlay.Managed == nil)
}

func applyClientRouteOverlay(configYAML string, overlay *ClientRouteOverlay) (string, error) {
	if overlay.empty() {
		return configYAML, nil
	}
	if len(overlay.Rules) > maxClientRouteRules {
		return "", errors.New("too many rules")
	}
	if len(overlay.RuleProviders) > maxClientRouteProviders {
		return "", errors.New("too many rule providers")
	}

	var view clientRouteConfigView
	if err := commonYaml.Unmarshal([]byte(configYAML), &view); err != nil {
		return "", errors.New("base config malformed")
	}
	var document map[string]any
	if err := commonYaml.Unmarshal([]byte(configYAML), &document); err != nil {
		return "", errors.New("base config malformed")
	}
	if document == nil {
		return "", errors.New("base config empty")
	}

	allowedTargets := map[string]struct{}{
		"DIRECT": {},
		"REJECT": {},
	}
	for _, group := range view.ProxyGroups {
		hidden, _ := group["hidden"].(bool)
		if hidden {
			continue
		}
		name, _ := group["name"].(string)
		name = strings.TrimSpace(name)
		if name != "" {
			allowedTargets[name] = struct{}{}
		}
	}
	baseRules := view.Rules
	if overlay.Managed != nil {
		primaryGroup, err := installClientManagedServerGroup(document)
		if err != nil {
			return "", err
		}
		baseRules = buildClientManagedRules(primaryGroup, overlay.Managed)
		applyClientManagedDocument(document, overlay.Managed)
	}
	fallbackTarget := findBaseMatchTarget(baseRules)

	providerDefinitions := make(map[string]any, len(view.RuleProviders)+len(overlay.RuleProviders))
	if overlay.Managed == nil {
		for name, definition := range view.RuleProviders {
			providerDefinitions[name] = definition
		}
	}
	providerNames := make(map[string]string, len(overlay.RuleProviders))
	for name, provider := range overlay.RuleProviders {
		definition, internalName, err := buildClientRuleProvider(name, provider)
		if err != nil {
			return "", err
		}
		if _, exists := providerDefinitions[internalName]; exists {
			return "", errors.New("rule provider collision")
		}
		providerDefinitions[internalName] = definition
		providerNames[name] = internalName
	}

	localRules := make([]string, 0, len(overlay.Rules))
	for _, rule := range overlay.Rules {
		normalized, err := normalizeClientRouteRule(
			rule,
			allowedTargets,
			providerNames,
			fallbackTarget,
		)
		if err != nil {
			return "", err
		}
		localRules = append(localRules, normalized)
	}

	document["rules"] = append(localRules, baseRules...)
	if len(providerDefinitions) > 0 {
		document["rule-providers"] = providerDefinitions
	} else if overlay.Managed != nil {
		delete(document, "rule-providers")
	}
	merged, err := commonYaml.Marshal(document)
	if err != nil {
		return "", errors.New("route overlay encode failed")
	}
	return string(merged), nil
}

func installClientManagedServerGroup(document map[string]any) (string, error) {
	rawGroups, _ := document["proxy-groups"].([]any)
	groupTypes := make(map[string]string, len(rawGroups))
	for _, rawGroup := range rawGroups {
		group, _ := rawGroup.(map[string]any)
		name, _ := group["name"].(string)
		typeName, _ := group["type"].(string)
		if strings.EqualFold(strings.TrimSpace(name), clientManagedServerGroup) {
			return "", errors.New("managed proxy group collision")
		}
		if strings.TrimSpace(name) != "" {
			groupTypes[name] = strings.ToLower(strings.TrimSpace(typeName))
		}
	}

	rawProxies, ok := document["proxies"].([]any)
	if !ok || len(rawProxies) == 0 {
		return "", errors.New("managed proxy group missing")
	}
	serverNames := make([]any, 0, len(rawProxies))
	seen := make(map[string]struct{}, len(rawProxies))
	for _, rawGroup := range rawGroups {
		group, _ := rawGroup.(map[string]any)
		hidden, _ := group["hidden"].(bool)
		typeName, _ := group["type"].(string)
		name, _ := group["name"].(string)
		if hidden || !strings.EqualFold(strings.TrimSpace(typeName), "select") || strings.TrimSpace(name) == "" {
			continue
		}
		members, _ := group["proxies"].([]any)
		for _, rawMember := range members {
			member, _ := rawMember.(string)
			memberType, exists := groupTypes[member]
			if !exists || (memberType != "url-test" && memberType != "fallback" && memberType != "load-balance") {
				continue
			}
			seen[member] = struct{}{}
			serverNames = append(serverNames, member)
			break
		}
		if len(serverNames) != 0 {
			break
		}
	}
	for _, rawProxy := range rawProxies {
		proxy, ok := rawProxy.(map[string]any)
		if !ok {
			continue
		}
		name, _ := proxy["name"].(string)
		if strings.TrimSpace(name) == "" {
			continue
		}
		// Mihomo proxy names are byte-exact identifiers.  Trimming here made
		// distinct names such as "Japan" and "Japan " collapse into one entry
		// in the managed selector and also changed which proxy was selected.
		if _, exists := seen[name]; exists {
			continue
		}
		seen[name] = struct{}{}
		serverNames = append(serverNames, name)
	}
	if len(serverNames) == 0 {
		return "", errors.New("managed proxy group missing")
	}

	document["proxy-groups"] = append(rawGroups, map[string]any{
		"name":    clientManagedServerGroup,
		"type":    "select",
		"proxies": serverNames,
	})
	return clientManagedServerGroup, nil
}

type clientManagedRuleTargets struct {
	Mainland string
	Overseas string
}

func (mode ClientManagedRouteMode) splitPolicy() bool {
	return mode == clientManagedRouteBypassMainland || mode == clientManagedRouteBypassOverseas
}

func (routing ClientManagedRouting) targets(primaryGroup string) clientManagedRuleTargets {
	mainlandTarget := primaryGroup
	overseasTarget := primaryGroup
	bypassMainland, bypassOverseas := routing.effectiveMode().legacyFlags()
	if bypassMainland {
		mainlandTarget = "DIRECT"
	}
	if bypassOverseas {
		overseasTarget = "DIRECT"
	}
	return clientManagedRuleTargets{
		Mainland: mainlandTarget,
		Overseas: overseasTarget,
	}
}

func buildClientManagedRules(primaryGroup string, routing *ClientManagedRouting) []string {
	targets := routing.targets(primaryGroup)
	if routing.effectiveMode().splitPolicy() {
		rules := []string{
			"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",
			"GEOSITE,google," + targets.Overseas,
			"GEOSITE,youtube," + targets.Overseas,
			"GEOSITE,google-play," + targets.Overseas,
			"GEOIP,private,DIRECT,no-resolve",
			"GEOIP,LAN,DIRECT,no-resolve",
			"GEOSITE,private,DIRECT",
		}
		if routing.RejectIPv6 {
			rules = append(rules, "IP-CIDR6,::/0,REJECT,no-resolve")
		}
		return append(rules,
			"IP-CIDR,223.5.5.5/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,223.6.6.6/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2400:3200::1/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2400:3200:baba::1/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR,119.29.29.29/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,1.12.12.12/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,120.53.53.53/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2402:4e00::/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2402:4e00:1::/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR,180.76.76.76/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2400:da00::6666/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.114.114/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.115.115/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.114.119/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.115.119/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.114.110/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,114.114.115.110/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,180.184.1.1/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,180.184.2.2/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,101.226.4.6/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,218.30.118.6/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,123.125.81.6/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,140.207.198.6/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,1.2.4.8/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,210.2.4.8/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,52.80.66.66/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,117.50.22.22/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2400:7fc0:849e:200::4/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2404:c2c0:85d8:901::4/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR,117.50.10.10/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,52.80.52.52/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2400:7fc0:849e:200::8/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR6,2404:c2c0:85d8:901::8/128,"+targets.Mainland+",no-resolve",
			"IP-CIDR,117.50.60.30/32,"+targets.Mainland+",no-resolve",
			"IP-CIDR,52.80.60.30/32,"+targets.Mainland+",no-resolve",
			"DOMAIN-SUFFIX,alidns.com,"+targets.Mainland,
			"DOMAIN-SUFFIX,doh.pub,"+targets.Mainland,
			"DOMAIN-SUFFIX,dot.pub,"+targets.Mainland,
			"DOMAIN-SUFFIX,360.cn,"+targets.Mainland,
			"DOMAIN-SUFFIX,onedns.net,"+targets.Mainland,
			"GEOIP,CN,"+targets.Mainland+",no-resolve",
			"GEOSITE,cn,"+targets.Mainland,
			"MATCH,"+targets.Overseas,
		)
	}
	rules := []string{
		"GEOIP,private,DIRECT,no-resolve",
		"GEOIP,LAN,DIRECT,no-resolve",
	}
	if routing.RejectIPv6 {
		rules = append(rules, "IP-CIDR6,::/0,REJECT,no-resolve")
	}
	return append(rules,
		"GEOSITE,google,"+targets.Overseas,
		"GEOSITE,youtube,"+targets.Overseas,
		"GEOSITE,google-play,"+targets.Overseas,
		"GEOSITE,cn,"+targets.Mainland,
		"GEOIP,CN,"+targets.Mainland,
		"MATCH,"+targets.Overseas,
	)
}

func applyClientManagedDocument(document map[string]any, routing *ClientManagedRouting) {
	document["mode"] = "rule"
	document["allow-lan"] = false
	document["geodata-mode"] = true
	document["geo-auto-update"] = true
	document["geo-update-interval"] = 168
	geoXURL, _ := document["geox-url"].(map[string]any)
	if geoXURL == nil {
		geoXURL = make(map[string]any)
	}
	geoXURL["geoip"] = clientGeoIPURL
	geoXURL["geosite"] = clientGeoSiteURL
	document["geox-url"] = geoXURL

	dns, _ := document["dns"].(map[string]any)
	if dns == nil {
		dns = make(map[string]any)
	}
	dns["enable"] = true
	dns["ipv6"] = false
	dns["prefer-h3"] = false
	dns["respect-rules"] = true
	dns["enhanced-mode"] = "redir-host"
	dns["default-nameserver"] = []any{"223.5.5.5", "119.29.29.29"}
	dns["proxy-server-nameserver"] = []any{"223.5.5.5", "119.29.29.29"}
	dns["nameserver"] = []any{clientOtherDNS}
	dns["nameserver-policy"] = map[string]any{
		clientMainlandDNSPolicy: []any{clientMainlandDNS},
	}
	for _, key := range []string{
		"proxy-server-nameserver-policy",
		"direct-nameserver",
		"direct-nameserver-follow-policy",
		"fallback",
		"fallback-filter",
		"fake-ip-range",
		"fake-ip-range6",
		"fake-ip-filter",
		"fake-ip-filter-mode",
		"fake-ip-ttl",
	} {
		delete(dns, key)
	}
	document["dns"] = dns
	profile, _ := document["profile"].(map[string]any)
	if profile == nil {
		profile = make(map[string]any)
	}
	profile["store-fake-ip"] = false
	document["profile"] = profile

	if routing.effectiveMode().splitPolicy() {
		sniffer, _ := document["sniffer"].(map[string]any)
		if sniffer == nil {
			sniffer = make(map[string]any)
		}
		sniffer["enable"] = true
		sniffer["force-dns-mapping"] = true
		sniffer["parse-pure-ip"] = true
		sniffer["override-destination"] = true
		sniffer["sniff"] = map[string]any{
			"HTTP": map[string]any{
				"ports":                []any{"1-65535"},
				"override-destination": true,
			},
			"TLS": map[string]any{
				"ports": []any{"1-65535"},
			},
			"QUIC": map[string]any{
				"ports": []any{"1-65535"},
			},
		}
		document["sniffer"] = sniffer
	}
}

func buildClientRuleProvider(
	name string,
	provider ClientRuleProviderConfig,
) (map[string]any, string, error) {
	name = strings.TrimSpace(name)
	if !validClientRuleProviderName(name) {
		return nil, "", errors.New("invalid rule provider name")
	}
	parsed, err := url.Parse(strings.TrimSpace(provider.URL))
	if err != nil ||
		!strings.EqualFold(parsed.Scheme, "https") ||
		parsed.Hostname() == "" ||
		parsed.User != nil ||
		len(provider.URL) > 2048 {
		return nil, "", errors.New("invalid rule provider URL")
	}
	behavior := strings.ToLower(strings.TrimSpace(provider.Behavior))
	if behavior == "" {
		behavior = "classical"
	}
	switch behavior {
	case "domain", "ipcidr", "classical":
	default:
		return nil, "", errors.New("invalid rule provider behavior")
	}
	format := strings.ToLower(strings.TrimSpace(provider.Format))
	if format == "" {
		format = "yaml"
	}
	switch format {
	case "yaml", "text", "mrs":
	default:
		return nil, "", errors.New("invalid rule provider format")
	}
	if format == "mrs" && behavior == "classical" {
		return nil, "", errors.New("mrs rule provider must use domain or ipcidr behavior")
	}
	interval := provider.Interval
	if interval == 0 {
		interval = 86400
	}
	if interval < 300 || interval > 604800 {
		return nil, "", errors.New("invalid rule provider interval")
	}

	sum := sha256.Sum256([]byte(name + "\x00" + parsed.String()))
	internalName := "__neutralvendor_local_" + hex.EncodeToString(sum[:8])
	extension := format
	if extension == "text" {
		extension = "txt"
	}
	definition := map[string]any{
		"type":       "http",
		"url":        parsed.String(),
		"behavior":   behavior,
		"format":     format,
		"interval":   interval,
		"path":       "./" + internalName + "." + extension,
		"size-limit": 8 << 20,
	}
	return definition, internalName, nil
}

func validClientRuleProviderName(name string) bool {
	if name == "" || len([]rune(name)) > 64 || strings.HasPrefix(name, "__neutralvendor_local_") {
		return false
	}
	for _, char := range name {
		if char == ',' || char == '\n' || char == '\r' || unicode.IsControl(char) {
			return false
		}
	}
	return true
}

func findBaseMatchTarget(rules []string) string {
	for index := len(rules) - 1; index >= 0; index-- {
		ruleType, _, target, _ := ruleCommon.ParseRulePayload(rules[index], true)
		if ruleType == "MATCH" && strings.TrimSpace(target) != "" {
			return strings.TrimSpace(target)
		}
	}
	return ""
}

func normalizeClientRouteRule(
	rule string,
	allowedTargets map[string]struct{},
	providerNames map[string]string,
	fallbackTarget string,
) (string, error) {
	rule = strings.TrimSpace(rule)
	if rule == "" || len(rule) > maxClientRouteRuleLength || strings.ContainsAny(rule, "\r\n") {
		return "", errors.New("invalid rule")
	}
	ruleType, payload, target, params := ruleCommon.ParseRulePayload(rule, true)
	if ruleType == "" || target == "" {
		return "", errors.New("invalid rule format")
	}
	if ruleType == "SUB-RULE" {
		return "", errors.New("local sub-rules are not supported")
	}
	if strings.EqualFold(target, "MATCH") {
		if fallbackTarget == "" {
			return "", errors.New("base MATCH target missing")
		}
		target = fallbackTarget
	}
	if _, ok := allowedTargets[target]; !ok {
		upperTarget := strings.ToUpper(target)
		if _, ok = allowedTargets[upperTarget]; !ok {
			return "", errors.New("invalid rule target")
		}
		target = upperTarget
	}
	if ruleType == "RULE-SET" {
		internalName, ok := providerNames[strings.TrimSpace(payload)]
		if !ok {
			return "", errors.New("local rule provider not found")
		}
		payload = internalName
	}
	return formatClientRouteRule(ruleType, payload, target, params), nil
}

func formatClientRouteRule(ruleType, payload, target string, params []string) string {
	parts := []string{ruleType}
	if ruleType != "MATCH" {
		parts = append(parts, payload)
	}
	parts = append(parts, target)
	parts = append(parts, params...)
	return strings.Join(parts, ",")
}

func clientRouteOverlayError(err error) string {
	if err == nil {
		return ""
	}
	return fmt.Sprintf("%s: %s", clientRouteOverlayErrorPrefix, err.Error())
}
