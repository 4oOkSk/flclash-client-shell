package dns

import (
	"testing"

	"github.com/metacubex/mihomo/component/trie"
)

type resetTestClient struct {
	dnsClient
	resets int
}

func (client *resetTestClient) ResetConnection() { client.resets++ }

func TestResetConnectionIncludesPolicyResolvers(t *testing.T) {
	mainClient := &resetTestClient{}
	matcherClient := &resetTestClient{}
	trieClient := &resetTestClient{}
	bootstrapClient := &resetTestClient{}
	policies := trie.New[[]dnsClient]()
	if err := policies.Insert("example.com", []dnsClient{trieClient}); err != nil {
		t.Fatal(err)
	}
	resolver := &Resolver{
		main: []dnsClient{mainClient},
		policy: []dnsPolicy{
			domainMatcherPolicy{dnsClients: []dnsClient{matcherClient}},
			domainTriePolicy{policies},
		},
		defaultResolver: &Resolver{main: []dnsClient{bootstrapClient}},
	}
	resolver.ResetConnection()
	for _, client := range []*resetTestClient{mainClient, matcherClient, trieClient, bootstrapClient} {
		if client.resets != 1 {
			t.Fatalf("resolver transport reset count = %d, want 1", client.resets)
		}
	}
}
