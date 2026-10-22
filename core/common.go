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
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/keepalive"
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
	currentConfig           *config.Config
	version                 = 0
	isRunning               = false
	runLock                 sync.Mutex
	mBatch, _               = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](50))
	debugError              = false
	applyRuntimeConfig      = hub.ApplyConfig
	errCoreListenersStopped = errors.New("core listeners stopped")
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
		return err
	case *rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		_, _, err := rsp.SideUpdate(bytes)
		return err
	default:
		return errors.New("not external provider")
	}
}

func updateListeners() error {
	if !isRunning {
		return nil
	}
	if currentConfig == nil {
		return errors.New("no applied configuration")
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	inboundErr := listener.PatchInboundListeners(listeners, tunnel.Tunnel, true)

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
	if inboundErr != nil {
		return inboundErr
	}
	ports := listener.GetPorts()
	if ports.Port != general.Port || ports.SocksPort != general.SocksPort ||
		ports.RedirPort != general.RedirPort || ports.TProxyPort != general.TProxyPort ||
		ports.MixedPort != general.MixedPort || ports.ShadowSocksConfig != general.ShadowSocksConfig ||
		ports.VmessConfig != general.VmessConfig {
		return errors.New("one or more proxy listeners could not bind")
	}
	if general.TuicServer.Enable && !listener.GetTuicConf().Enable {
		return errors.New("TUIC listener could not start")
	}
	if !features.Android && general.Tun.Enable && !listener.IsTunRunning() {
		return errors.New("TUN listener could not start")
	}
	return nil
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

func updateConfig(params *UpdateParams) error {
	runLock.Lock()
	defer runLock.Unlock()
	if currentConfig == nil || currentConfig.General == nil {
		return errors.New("config not applied")
	}
	general := currentConfig.General
	// Parse local Hosts before changing any live setting.
	if params.Hosts != nil {
		hosts := make(map[string]any, len(*params.Hosts))
		for host, value := range *params.Hosts {
			hosts[host] = value
		}
		tree, err := config.ParseHosts(&config.RawConfig{Hosts: hosts})
		if err != nil {
			return err
		}
		currentConfig.Hosts = tree
		resolver.DefaultHosts = resolver.NewHosts(tree)
	}
	reloadRuntimeConfig := false
	patchConfigValue(&general.MixedPort, params.MixedPort)
	patchConfigValue(&general.Port, params.Port)
	patchConfigValue(&general.SocksPort, params.SocksPort)
	patchConfigValue(&general.RedirPort, params.RedirPort)
	patchConfigValue(&general.TProxyPort, params.TProxyPort)
	patchConfigValue(&general.GlobalUA, params.GlobalUA, mihomoHttp.SetUA)
	patchConfigValue(&general.KeepAliveInterval, params.KeepAliveInterval, func(value int) {
		keepalive.SetKeepAliveInterval(time.Duration(value) * time.Second)
	})
	patchConfigValue(&general.GeodataLoader, params.GeodataLoader, geodata.SetLoader)
	patchConfigValue(&general.AllowLan, params.AllowLan)
	patchConfigValue(&general.Sniffing, params.Sniffing, tunnel.SetSniffing)
	patchConfigValue(&general.FindProcessMode, params.FindProcessMode, tunnel.SetFindProcessMode)
	patchConfigValue(&general.TCPConcurrent, params.TCPConcurrent, dialer.SetTcpConcurrent)
	patchConfigValue(&general.Interface, params.Interface, dialer.DefaultInterface.Store)
	patchConfigValue(&general.UnifiedDelay, params.UnifiedDelay, adapter.UnifiedDelay.Store)
	patchConfigValue(&general.Mode, params.Mode, tunnel.SetMode)
	patchConfigValue(&general.LogLevel, params.LogLevel, log.SetLevel)
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
		patchConfigValue(&general.Tun.AutoRoute, params.Tun.AutoRoute)
		patchConfigValue(&general.Tun.Device, params.Tun.Device)
		patchConfigValue(&general.Tun.RouteAddress, params.Tun.RouteAddress)
		patchConfigValue(&general.Tun.DNSHijack, params.Tun.DNSHijack)
		patchConfigValue(&general.Tun.Stack, params.Tun.Stack)
	}

	updateGeoUpdatePolicy(params)

	if reloadRuntimeConfig {
		// DNS resolvers and fake-IP mappers capture the IPv6 setting when the
		// config is applied. Reapply it so a local IPv4-only TUN cannot keep
		// serving unusable fake AAAA answers from the downloaded profile.
		selectedMap := snapshotSelectGroup()
		applyRuntimeConfig(currentConfig)
		observeClientDiagnosticResolver()
		patchSelectGroup(selectedMap)
	}
	if err := updateListeners(); err != nil {
		isRunning = false
		stopListeners()
		return err
	}
	updater.RegisterGeoUpdaterWithCancel()
	return nil
}

func updateGeoUpdatePolicy(params *UpdateParams) {
	general := currentConfig.General
	patchConfigValue(&general.GeoAutoUpdate, params.GeoAutoUpdate)
	patchConfigValue(&general.GeoUpdateInterval, params.GeoUpdateInterval)
	updater.SetGeoAutoUpdate(general.GeoAutoUpdate)
	updater.SetGeoUpdateInterval(general.GeoUpdateInterval)
}

func applyConfig(params *SetupParams) error {
	runtime.GC()
	runLock.Lock()
	defer runLock.Unlock()
	previousNames := append([]string(nil), config.GetProxyNameList()...)
	restoreUsage := geodata.SnapshotUsage()
	committed := false
	defer func() {
		if !committed {
			config.SetProxyNameList(previousNames)
			restoreUsage()
		}
	}()
	nextConfig, err := executor.ParseWithPath(filepath.Join(constant.Path.HomeDir(), "config.yaml"))
	if err != nil {
		return err
	}
	previousConfig := currentConfig
	currentConfig = nextConfig
	// Validate listener readiness before publishing new routing/runtime state.
	// On failure the old configuration remains available,
	// but the partially recreated listeners must be stopped explicitly.
	if err := updateListeners(); err != nil {
		currentConfig = previousConfig
		isRunning = false
		stopListeners()
		return fmt.Errorf("%w: %v", errCoreListenersStopped, err)
	}
	constant.DefaultTestURL = params.TestURL
	applyRuntimeConfig(currentConfig)
	if isRunning && !features.Android {
		// Applying general runtime settings resets routing marks/interface lookup.
		// The already-validated TUN takes its same-config OnReload path here,
		// restoring those owned hooks without closing/recreating the adapter.
		listener.ReCreateTun(currentConfig.General.Tun, tunnel.Tunnel)
	}
	committed = true
	observeClientDiagnosticResolver()
	patchSelectGroup(params.SelectedMap)
	updater.RegisterGeoUpdaterWithCancel()
	return nil
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
