//go:build with_gvisor

package main

import (
	"testing"

	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	tun "github.com/metacubex/sing-tun"
)

type observedTunEndpoint struct {
	stack.LinkEndpoint
	dispatcher  stack.NetworkDispatcher
	attachCalls int
}

func (endpoint *observedTunEndpoint) Attach(dispatcher stack.NetworkDispatcher) {
	endpoint.dispatcher = dispatcher
	endpoint.attachCalls++
}

type observedTunDispatcher struct {
	stack.NetworkDispatcher
}

func TestTunFilterPreservesAttachAndDetach(test *testing.T) {
	endpoint := &observedTunEndpoint{}
	filter := &tun.LinkEndpointFilter{LinkEndpoint: endpoint}
	dispatcher := &observedTunDispatcher{}
	filter.Attach(dispatcher)
	if endpoint.dispatcher == nil || endpoint.dispatcher == dispatcher {
		test.Fatal("normal attach must still install the packet filter")
	}
	filter.Attach(nil)
	if endpoint.dispatcher != nil {
		test.Fatalf("detach signal became %T instead of nil", endpoint.dispatcher)
	}
	filter.Attach(nil)
	if endpoint.dispatcher != nil || endpoint.attachCalls != 3 {
		test.Fatal("repeated detach must still reach the underlying endpoint")
	}
}
