package main

import (
	"net/netip"

	"github.com/metacubex/mihomo/component/resolver"
)

func observeClientDiagnosticResolver() {
	resolver.SetLookupObserver(func(host string, addresses []netip.Addr) {
		if endpoints, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet); endpoints != nil {
			endpoints.recordAddresses(host, addresses)
		}
	})
}
