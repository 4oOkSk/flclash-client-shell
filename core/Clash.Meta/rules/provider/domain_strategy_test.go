package provider_test

import (
	"bytes"
	"testing"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/rules/provider"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDomainStrategyDumpMrs(t *testing.T) {
	tests := []struct {
		name     string
		domains  []string
		expected []string
		queries  map[string]bool
	}{
		{
			"suffix-only",
			[]string{".example.com"},
			[]string{".example.com"},
			map[string]bool{"example.com": false, "www.example.com": true},
		},
		{
			"exact-only",
			[]string{"example.com"},
			[]string{"example.com"},
			map[string]bool{"example.com": true, "www.example.com": false},
		},
		{
			"merge-terminals",
			[]string{"example.com", ".example.com"},
			[]string{"+.example.com"},
			map[string]bool{"example.com": true, "www.example.com": true},
		},
		{
			"deduplicate",
			[]string{"+.example.com", "+.example.com", "example.com", ".example.com"},
			[]string{"+.example.com"},
			map[string]bool{"example.com": true, "www.example.com": true},
		},
		{
			"mixed",
			[]string{".example.com", "example.net", "example.org", ".example.org"},
			[]string{"+.example.org", ".example.com", "example.net"},
			map[string]bool{
				"example.com":     false,
				"www.example.com": true,
				"example.net":     true,
				"www.example.net": false,
				"example.org":     true,
				"www.example.org": true,
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			strategy := provider.NewDomainStrategy()
			strategy.Reset()
			for _, domain := range test.domains {
				strategy.Insert(domain)
			}
			strategy.FinishInsert()
			var binary bytes.Buffer
			require.NoError(t, strategy.WriteMrs(&binary))
			loaded := provider.NewDomainStrategy()
			require.NoError(t, loaded.FromMrs(&binary, strategy.Count()))
			rebuilt := provider.NewDomainStrategy()
			rebuilt.Reset()
			var domains []string
			loaded.DumpMrs(func(domain string) bool {
				domains = append(domains, domain)
				rebuilt.Insert(domain)
				return true
			})
			rebuilt.FinishInsert()
			assert.Equal(t, test.expected, domains)
			for domain, expected := range test.queries {
				metadata := &constant.Metadata{Host: domain}
				assert.Equal(t, expected, strategy.Match(metadata, constant.RuleMatchHelper{}), domain)
				assert.Equal(t, expected, loaded.Match(metadata, constant.RuleMatchHelper{}), domain)
				assert.Equal(t, expected, rebuilt.Match(metadata, constant.RuleMatchHelper{}), domain)
			}
			calls := 0
			loaded.DumpMrs(func(string) bool {
				calls++
				return false
			})
			assert.Equal(t, 1, calls)
		})
	}
}
