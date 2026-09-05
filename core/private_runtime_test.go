package main

import (
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	M "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestGeoUpdatePolicyRespectsConfigOwnership(test *testing.T) {
	oldConfig, oldPrivate := currentConfig, privateConfig
	oldAutoUpdate, oldInterval := updater.GeoAutoUpdate(), updater.GeoUpdateInterval()
	test.Cleanup(func() {
		currentConfig, privateConfig = oldConfig, oldPrivate
		updater.SetGeoAutoUpdate(oldAutoUpdate)
		updater.SetGeoUpdateInterval(oldInterval)
	})
	for _, managed := range []bool{true, false} {
		parsed, err := config.ParseRawConfig(config.DefaultRawConfig())
		if err != nil {
			test.Fatal(err)
		}
		currentConfig, privateConfig = parsed, managed
		currentConfig.General.GeoAutoUpdate = true
		currentConfig.General.GeoUpdateInterval = 168
		requestedAutoUpdate, requestedInterval := false, 24
		updateGeoUpdatePolicy(&UpdateParams{
			GeoAutoUpdate:     &requestedAutoUpdate,
			GeoUpdateInterval: &requestedInterval,
		})
		wantAutoUpdate, wantInterval := false, 24
		if managed {
			wantAutoUpdate, wantInterval = true, 168
		}
		if updater.GeoAutoUpdate() != wantAutoUpdate || updater.GeoUpdateInterval() != wantInterval {
			test.Fatalf("managed=%v updater=%v/%d want=%v/%d", managed,
				updater.GeoAutoUpdate(), updater.GeoUpdateInterval(), wantAutoUpdate, wantInterval)
		}
		if currentConfig.General.GeoAutoUpdate != wantAutoUpdate || currentConfig.General.GeoUpdateInterval != wantInterval {
			test.Fatal("runtime policy and stored configuration diverged")
		}
	}
}

func TestPrivateConfigAcceptsLocalRuntimePatch(t *testing.T) {
	oldConfig := currentConfig
	oldPrivate := privateConfig
	oldRunning := isRunning
	oldApplyRuntimeConfig := applyRuntimeConfig
	t.Cleanup(func() {
		currentConfig = oldConfig
		privateConfig = oldPrivate
		isRunning = oldRunning
		applyRuntimeConfig = oldApplyRuntimeConfig
	})

	parsed, err := config.ParseRawConfig(config.DefaultRawConfig())
	if err != nil {
		t.Fatalf("parse default config: %v", err)
	}
	currentConfig = parsed
	currentConfig.General.IPv6 = true
	privateConfig = true
	isRunning = false
	runtimeConfigApplies := 0
	applyRuntimeConfig = func(*config.Config) {
		runtimeConfigApplies++
	}

	mixedPort := 12002
	allowLan := true
	mode := tunnel.Global
	stack := M.TunMixed
	device := "HarborProxy"
	autoRoute := true
	dnsHijack := []string{"any:53"}
	ipv6 := false
	updateConfig(&UpdateParams{
		MixedPort: &mixedPort,
		AllowLan:  &allowLan,
		Mode:      &mode,
		IPv6:      &ipv6,
		Tun: &tunSchema{
			Enable:    true,
			Device:    &device,
			AutoRoute: &autoRoute,
			Stack:     &stack,
			DNSHijack: &dnsHijack,
		},
	})

	if !privateConfig {
		t.Fatal("expected private config mode")
	}
	if currentConfig.General.MixedPort != mixedPort {
		t.Fatalf("mixed port = %d, want %d", currentConfig.General.MixedPort, mixedPort)
	}
	if !currentConfig.General.AllowLan {
		t.Fatal("allow-lan local patch was not applied")
	}
	if currentConfig.General.Mode != tunnel.Global {
		t.Fatalf("mode = %v, want global", currentConfig.General.Mode)
	}
	if !currentConfig.General.Tun.Enable || !currentConfig.General.Tun.AutoRoute {
		t.Fatal("TUN local patch was not applied")
	}
	if currentConfig.General.IPv6 {
		t.Fatal("IPv6 local patch was not applied")
	}
	if runtimeConfigApplies != 1 {
		t.Fatalf("runtime config applied %d times, want 1", runtimeConfigApplies)
	}
}

func TestPrivateSelectorRestoresAndChangesExplicitServer(t *testing.T) {
	oldConfig := currentConfig
	oldPrivate := privateConfig
	oldRunning := isRunning
	t.Cleanup(func() {
		currentConfig = oldConfig
		privateConfig = oldPrivate
		isRunning = oldRunning
	})
	isRunning = false

	const managedConfig = `
mode: rule
proxies:
  - name: node-a
    type: socks5
    server: 127.0.0.1
    port: 1
  - name: node-b
    type: socks5
    server: 127.0.0.1
    port: 2
proxy-groups:
  - name: managed-main
    type: select
    proxies:
      - node-a
      - node-b
rules:
  - MATCH,managed-main
`
	if err := applyConfig(&SetupParams{
		Config:      managedConfig,
		SelectedMap: map[string]string{"managed-main": "node-b"},
	}); err != nil {
		t.Fatal(err)
	}
	managed := tunnel.AllProxies()["managed-main"].(*adapter.Proxy)
	group := managed.ProxyAdapter.(outboundgroup.ProxyGroup)
	if got := group.Now(); got != "node-b" {
		t.Fatalf("restored selection = %q, want node-b", got)
	}

	groupName, proxyName := "managed-main", "node-a"
	result := make(chan string, 1)
	handleChangeProxy(&ChangeProxyParams{
		GroupName: groupName,
		ProxyName: proxyName,
	}, func(message string) {
		result <- message
	})
	select {
	case message := <-result:
		if message != "" {
			t.Fatalf("change proxy returned %q", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("change proxy timed out")
	}
	if got := group.Now(); got != "node-a" {
		t.Fatalf("live selection = %q, want node-a", got)
	}
}

func TestPrivateGlobalDefaultsToManagedGroup(t *testing.T) {
	oldConfig := currentConfig
	oldPrivate := privateConfig
	oldRunning := isRunning
	t.Cleanup(func() {
		currentConfig = oldConfig
		privateConfig = oldPrivate
		isRunning = oldRunning
	})
	isRunning = false

	const managedConfig = `
mode: rule
proxies:
  - name: managed-node
    type: socks5
    server: 127.0.0.1
    port: 1
proxy-groups:
  - name: managed-main
    type: select
    proxies:
      - managed-node
rules:
  - MATCH,managed-main
`
	if err := applyConfig(&SetupParams{Config: managedConfig, SelectedMap: map[string]string{}}); err != nil {
		t.Fatal(err)
	}
	global := tunnel.AllProxies()["GLOBAL"].(*adapter.Proxy)
	group := global.ProxyAdapter.(outboundgroup.ProxyGroup)
	if got := group.Now(); got != "managed-main" {
		t.Fatalf("GLOBAL = %q, want managed-main", got)
	}

	if err := applyConfig(&SetupParams{
		Config:      managedConfig,
		SelectedMap: map[string]string{"GLOBAL": "DIRECT"},
	}); err != nil {
		t.Fatal(err)
	}
	global = tunnel.AllProxies()["GLOBAL"].(*adapter.Proxy)
	group = global.ProxyAdapter.(outboundgroup.ProxyGroup)
	if got := group.Now(); got != "DIRECT" {
		t.Fatalf("explicit GLOBAL selection = %q, want DIRECT", got)
	}
}
