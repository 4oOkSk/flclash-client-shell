package main

import (
	b "bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	currentConfig      *config.Config
	version            = 0
	isRunning          = false
	privateConfig      = false
	runLock            sync.Mutex
	mBatch, _          = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](50))
	debugError         = false
	applyRuntimeConfig = hub.ApplyConfig
)

func getExternalProvidersRaw() map[string]cp.Provider {
	eps := make(map[string]cp.Provider)
	for n, p := range tunnel.Providers() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	for n, p := range tunnel.RuleProviders() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	return eps
}

func toExternalProvider(p cp.Provider) (*ExternalProvider, error) {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		return &ExternalProvider{
			Name:             psp.Name(),
			Type:             psp.Type().String(),
			VehicleType:      psp.VehicleType().String(),
			Count:            psp.Count(),
			UpdateAt:         psp.UpdatedAt(),
			Path:             psp.Vehicle().Path(),
			SubscriptionInfo: psp.GetSubscriptionInfo(),
		}, nil
	case *rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		return &ExternalProvider{
			Name:        rsp.Name(),
			Type:        rsp.Type().String(),
			VehicleType: rsp.VehicleType().String(),
			Count:       rsp.Count(),
			UpdateAt:    rsp.UpdatedAt(),
			Path:        rsp.Vehicle().Path(),
		}, nil
	default:
		return nil, errors.New("not external provider")
	}
}

func sideUpdateExternalProvider(p cp.Provider, bytes []byte) error {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		_, _, err := psp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	case rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		_, _, err := rsp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	default:
		return errors.New("not external provider")
	}
}

func updateListeners() {
	if !isRunning {
		return
	}
	if currentConfig == nil {
		return
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	listener.PatchInboundListeners(listeners, tunnel.Tunnel, true)

	allowLan := general.AllowLan
	listener.SetAllowLan(allowLan)
	inbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	inbound.SetAllowedIPs(general.LanAllowedIPs)
	inbound.SetDisAllowedIPs(general.LanDisAllowedIPs)

	bindAddress := general.BindAddress
	listener.SetBindAddress(bindAddress)
	listener.ReCreateHTTP(general.Port, tunnel.Tunnel)
	listener.ReCreateSocks(general.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(general.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(general.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(general.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(general.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(general.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(general.TuicServer, tunnel.Tunnel)
	if !features.Android {
		listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	}
}

func stopListeners() {
	listener.StopListener()
}

func patchSelectGroup(mapping map[string]string) {
	for name, proxy := range tunnel.AllProxies() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		selector, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}

		selected, exist := mapping[name]
		if !exist {
			continue
		}

		selector.ForceSet(selected)
	}
}

// A synthetic GLOBAL selector starts at DIRECT in mihomo. In a managed client
// that makes the UI's Global mode silently bypass every proxy until the user
// also discovers and changes a second selector. Default it to the first real
// proxy group when the user has not saved an explicit GLOBAL choice.
func patchPrivateGlobalDefault(mapping map[string]string) {
	globalProxy, ok := tunnel.AllProxies()["GLOBAL"]
	if !ok || globalProxy == nil {
		return
	}
	globalAdapter, ok := globalProxy.(*adapter.Proxy)
	if !ok {
		return
	}
	globalSelector, ok := globalAdapter.ProxyAdapter.(outboundgroup.SelectAble)
	if !ok {
		return
	}
	globalGroup, ok := globalAdapter.ProxyAdapter.(outboundgroup.ProxyGroup)
	if !ok {
		return
	}

	if selected, exists := mapping["GLOBAL"]; exists {
		if selected == "DIRECT" || (selected != "" && globalGroup.Now() == selected) {
			return
		}
	}

	proxies := tunnel.AllProxies()
	for _, name := range config.GetProxyNameList() {
		if name == "GLOBAL" {
			continue
		}
		candidate, ok := proxies[name]
		if !ok || candidate == nil {
			continue
		}
		candidateAdapter, ok := candidate.(*adapter.Proxy)
		if !ok {
			continue
		}
		if _, ok := candidateAdapter.ProxyAdapter.(outboundgroup.ProxyGroup); !ok {
			continue
		}
		globalSelector.ForceSet(name)
		return
	}
}

func snapshotSelectGroup() map[string]string {
	mapping := make(map[string]string)
	for name, proxy := range tunnel.AllProxies() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		group, ok := outbound.ProxyAdapter.(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		if _, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble); !ok {
			continue
		}

		mapping[name] = group.Now()
	}
	return mapping
}

func defaultSetupParams() *SetupParams {
	return &SetupParams{
		TestURL:     "https://www.gstatic.com/generate_204",
		SelectedMap: map[string]string{},
	}
}

func readFile(path string) ([]byte, error) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	return data, err
}

func updateConfig(params *UpdateParams) {
	runLock.Lock()
	defer runLock.Unlock()
	general := currentConfig.General
	reloadRuntimeConfig := false
	if privateConfig {
		params.ExternalController = nil
	}
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.AllowLan != nil {
		general.AllowLan = *params.AllowLan
	}
	if params.Sniffing != nil {
		general.Sniffing = *params.Sniffing
		tunnel.SetSniffing(general.Sniffing)
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.Interface != nil {
		general.Interface = *params.Interface
		dialer.DefaultInterface.Store(general.Interface)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	if params.Mode != nil {
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	if params.IPv6 != nil {
		reloadRuntimeConfig = general.IPv6 != *params.IPv6
		general.IPv6 = *params.IPv6
		resolver.DisableIPv6 = !general.IPv6
	}
	if params.ExternalController != nil {
		currentConfig.Controller.ExternalController = *params.ExternalController
		route.ReCreateServer(&route.Config{
			Addr: currentConfig.Controller.ExternalController,
		})
	}

	if params.Tun != nil {
		general.Tun.Enable = params.Tun.Enable
		if params.Tun.AutoRoute != nil {
			general.Tun.AutoRoute = *params.Tun.AutoRoute
		}
		if params.Tun.Device != nil {
			general.Tun.Device = *params.Tun.Device
		}
		if params.Tun.RouteAddress != nil {
			general.Tun.RouteAddress = *params.Tun.RouteAddress
		}
		if params.Tun.DNSHijack != nil {
			general.Tun.DNSHijack = *params.Tun.DNSHijack
		}
		if params.Tun.Stack != nil {
			general.Tun.Stack = *params.Tun.Stack
		}
	}

	updateGeoUpdatePolicy(params)

	if reloadRuntimeConfig {
		// DNS resolvers and fake-IP mappers capture the IPv6 setting when the
		// config is applied. Reapply it so a local IPv4-only TUN cannot keep
		// serving unusable fake AAAA answers from the downloaded profile.
		selectedMap := snapshotSelectGroup()
		applyRuntimeConfig(currentConfig)
		patchSelectGroup(selectedMap)
	}
	updateListeners()
	updater.RegisterGeoUpdaterWithCancel()
}

func updateGeoUpdatePolicy(params *UpdateParams) {
	general := currentConfig.General
	if !privateConfig {
		if params.GeoAutoUpdate != nil {
			general.GeoAutoUpdate = *params.GeoAutoUpdate
		}
		if params.GeoUpdateInterval != nil {
			general.GeoUpdateInterval = *params.GeoUpdateInterval
		}
	}
	updater.SetGeoAutoUpdate(general.GeoAutoUpdate)
	updater.SetGeoUpdateInterval(general.GeoUpdateInterval)
}

func applyConfig(params *SetupParams) error {
	runtime.GC()
	runLock.Lock()
	defer runLock.Unlock()
	var err error
	constant.DefaultTestURL = params.TestURL
	// PATCH(ops): 有内存配置内容则用它(不落盘/不读盘), 否则回退磁盘 config.yaml
	if params.Config != "" {
		nextConfig, parseErr := executor.ParseWithBytes([]byte(params.Config))
		if parseErr != nil {
			return parseErr
		}
		lockDownInMemoryConfig(nextConfig)
		currentConfig = nextConfig
		privateConfig = true
	} else {
		currentConfig, err = executor.ParseWithPath(filepath.Join(constant.Path.HomeDir(), "config.yaml"))
		if err != nil {
			currentConfig, _ = config.ParseRawConfig(config.DefaultRawConfig())
		}
		privateConfig = false
	}
	hub.ApplyConfig(currentConfig)
	patchSelectGroup(params.SelectedMap)
	if privateConfig {
		patchPrivateGlobalDefault(params.SelectedMap)
	}
	updateListeners()
	updater.RegisterGeoUpdaterWithCancel()
	return err
}

func lockDownInMemoryConfig(cfg *config.Config) {
	if cfg == nil {
		return
	}
	if cfg.General != nil {
		cfg.General.Authentication = nil
		cfg.General.Interface = ""
		cfg.General.RoutingMark = 0
	}
	if cfg.Controller != nil {
		cfg.Controller.ExternalController = ""
		cfg.Controller.ExternalControllerTLS = ""
		cfg.Controller.ExternalControllerUnix = ""
		cfg.Controller.ExternalControllerPipe = ""
		cfg.Controller.ExternalUI = ""
		cfg.Controller.ExternalUIURL = ""
		cfg.Controller.ExternalUIName = ""
		cfg.Controller.ExternalDohServer = ""
		cfg.Controller.Secret = ""
		cfg.Controller.Cors = config.Cors{}
	}
}

func UnmarshalJson(data []byte, v any) error {
	decoder := json.NewDecoder(b.NewReader(data))
	decoder.UseNumber()
	err := decoder.Decode(v)
	return err
}

func logError(format string, args ...interface{}) {
	log.Errorln(format, args...)
	if debugError {
		fmt.Fprintf(os.Stderr, "[ERROR] "+format+"\n", args...)
	}
}
