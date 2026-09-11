package main

import (
	"context"
	"net/netip"

	"github.com/metacubex/mihomo/component/resolver"
)

type clientDiagnosticResolver struct {
	resolver.Resolver
	endpoints *clientDiagnosticEndpointSet
}

func observeClientDiagnosticResolver() {
	endpoints, _ := clientDiagnosticEndpoints.Load().(*clientDiagnosticEndpointSet)
	if endpoints == nil || resolver.ProxyServerHostResolver == nil {
		return
	}
	endpoints.mu.RLock()
	active := len(endpoints.hosts) != 0
	endpoints.mu.RUnlock()
	if active {
		upstream := resolver.ProxyServerHostResolver
		if observer, ok := upstream.(*clientDiagnosticResolver); ok {
			upstream = observer.Resolver
		}
		resolver.ProxyServerHostResolver = &clientDiagnosticResolver{
			Resolver:  upstream,
			endpoints: endpoints,
		}
	}
}

func (observer *clientDiagnosticResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	addresses, err := observer.Resolver.LookupIP(ctx, host)
	observer.endpoints.recordAddresses(host, addresses)
	return addresses, err
}

func (observer *clientDiagnosticResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	addresses, err := observer.Resolver.LookupIPv4(ctx, host)
	observer.endpoints.recordAddresses(host, addresses)
	return addresses, err
}

func (observer *clientDiagnosticResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	addresses, err := observer.Resolver.LookupIPv6(ctx, host)
	observer.endpoints.recordAddresses(host, addresses)
	return addresses, err
}
