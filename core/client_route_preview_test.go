package main

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
	Rules "github.com/metacubex/mihomo/rules"
	R "github.com/metacubex/mihomo/rules/common"
)

func TestClientRoutePreviewLogicalRules(test *testing.T) {
	cases := []struct{ name, kind, payload, status, action string }{
		{"managed UDP guard", "AND", "((NETWORK,UDP),(DST-PORT,443))", "matched", "direct"},
		{"unknown AND false", "AND", "((IP-CIDR,192.0.2.0/24),(NETWORK,UDP))", "matched", "direct"},
		{"unknown OR true", "OR", "((IP-CIDR,192.0.2.0/24),(NETWORK,TCP))", "matched", "reject"},
		{"unknown AND true", "AND", "((IP-CIDR,192.0.2.0/24),(NETWORK,TCP))", "needs-ip", ""},
		{"unknown OR false", "OR", "((IP-CIDR,192.0.2.0/24),(NETWORK,UDP))", "needs-ip", ""},
		{"NOT unknown", "NOT", "((IP-CIDR,192.0.2.0/24))", "needs-ip", ""},
		{"NOT UDP", "NOT", "((NETWORK,UDP))", "matched", "reject"},
		{"nested", "AND", "((NOT,((NETWORK,UDP))),(DST-PORT,443))", "matched", "reject"},
	}
	for _, item := range cases {
		test.Run(item.name, func(test *testing.T) {
			rule, err := Rules.ParseRule(item.kind, item.payload, "REJECT", nil, nil)
			if err != nil {
				test.Fatal(err)
			}
			result := previewClientRouteRules("example.com", []C.Rule{rule, R.NewMatch("DIRECT")})
			if result.Status != item.status || result.Action != item.action {
				test.Fatalf("got %+v", result)
			}
		})
	}
}

func TestClientRoutePreviewUsesCoreRuleOrder(test *testing.T) {
	rules := []C.Rule{
		R.NewDomainSuffix("example.com", "REJECT"),
		R.NewDomainSuffix("www.example.com", "DIRECT"),
		R.NewDomainSuffix("example.org", clientManagedServerGroup),
	}
	result := previewClientRouteRules("www.example.com", rules)
	if result.Status != "matched" || result.Action != "reject" || result.RuleIndex != 1 {
		test.Fatalf("unexpected first-match result: %+v", result)
	}
	result = previewClientRouteRules("example.org", rules)
	if result.Action != "proxy" || result.RuleIndex != 3 {
		test.Fatalf("unexpected managed route result: %+v", result)
	}
}

func TestClientRoutePreviewDoesNotGuessMissingIP(test *testing.T) {
	network, err := R.NewIPCIDR("192.0.2.0/24", "DIRECT")
	if err != nil {
		test.Fatal(err)
	}
	rules := []C.Rule{network, R.NewDomainSuffix("example.com", "REJECT")}
	if result := previewClientRouteRules("example.com", rules); result.Status != "needs-ip" {
		test.Fatalf("missing IP was guessed: %+v", result)
	}
	if result := previewClientRouteRules("192.0.2.1", rules); result.Status != "matched" || result.Action != "direct" {
		test.Fatalf("literal IP did not match core rule: %+v", result)
	}
	if result := previewClientRouteRules("https://user:password@example.com", rules); result.Status != "invalid" {
		test.Fatal("credentials must not be accepted as a routing destination")
	}
}
