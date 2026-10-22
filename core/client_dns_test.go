package main

import (
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
)

type clientResetTestResolver struct {
	resolver.Resolver
	resets int
}

func (current *clientResetTestResolver) ResetConnection() { current.resets++ }

func TestCloseConnectionsResetsDNSBeforeReturning(t *testing.T) {
	previous := resolver.DefaultResolver
	t.Cleanup(func() { resolver.DefaultResolver = previous })
	current := &clientResetTestResolver{}
	resolver.DefaultResolver = current
	if !handleCloseConnections() || current.resets != 1 {
		t.Fatal("server selection teardown left DNS transport connections open")
	}
}
